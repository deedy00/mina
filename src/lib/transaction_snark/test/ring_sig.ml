open Util
open Core
open Currency
open Mina_base
open Signature_lib
module Impl = Pickles.Impls.Step
module Inner_curve = Snark_params.Tick.Inner_curve
module Nat = Pickles_types.Nat
module Local_state = Mina_state.Local_state
module Parties_segment = Transaction_snark.Parties_segment
module Statement = Transaction_snark.Statement
open Snark_params.Tick
open Snark_params.Tick.Let_syntax

(* check a signature on msg against a public key *)
let check_sig pk msg sigma : (Boolean.var, _) Checked.t =
  let%bind (module S) = Inner_curve.Checked.Shifted.create () in
  Schnorr.Checked.verifies (module S) sigma pk msg

(* verify witness signature against public keys *)
let%snarkydef verify_sig pubkeys msg sigma =
  let%bind pubkeys =
    exists
      (Typ.list ~length:(List.length pubkeys) Inner_curve.typ)
      ~compute:(As_prover.return pubkeys)
  in
  Checked.List.exists pubkeys ~f:(fun pk -> check_sig pk msg sigma)
  >>= Boolean.Assert.is_true

let check_witness pubkeys msg witness =
  Transaction_snark.dummy_constraints ()
  >>= fun () -> verify_sig pubkeys msg witness

type _ Snarky_backendless.Request.t +=
  | Sigma : Schnorr.Signature.t Snarky_backendless.Request.t

let ring_sig_rule (ring_member_pks : Schnorr.Public_key.t list) :
    _ Pickles.Inductive_rule.t =
  let ring_sig_main (tx_commitment : Snapp_statement.Checked.t) :
      (unit, _) Checked.t =
    let msg_var =
      Snapp_statement.Checked.to_field_elements tx_commitment
      |> Random_oracle_input.field_elements
    in
    let%bind sigma_var =
      exists Schnorr.Signature.typ ~request:(As_prover.return Sigma)
    in
    check_witness ring_member_pks msg_var sigma_var
  in
  { identifier = "ring-sig-rule"
  ; prevs = []
  ; main =
      (fun [] x ->
        ring_sig_main x |> Run.run_checked
        |> fun _ :
               unit
               Pickles_types.Hlist0.H1
                 (Pickles_types.Hlist.E01(Pickles.Inductive_rule.B))
               .t ->
        [])
  ; main_value = (fun [] _ -> [])
  }

let%test_unit "1-of-1" =
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    let%map sk = Private_key.gen and msg = Field.gen_uniform in
    (sk, Random_oracle.Input.field_elements [| msg |])
  in
  Quickcheck.test ~trials:1 gen ~f:(fun (sk, msg) ->
      let pk = Inner_curve.(scale one sk) in
      (let sigma = Schnorr.sign sk msg in
       let%bind sigma_var, msg_var =
         exists
           Typ.(Schnorr.Signature.typ * Schnorr.message_typ ())
           ~compute:As_prover.(return (sigma, msg))
       in
       check_witness [ pk ] msg_var sigma_var)
      |> Checked.map ~f:As_prover.return
      |> Fn.flip run_and_check () |> Or_error.ok_exn |> snd)

let%test_unit "1-of-2" =
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    let%map sk0 = Private_key.gen
    and sk1 = Private_key.gen
    and msg = Field.gen_uniform in
    (sk0, sk1, Random_oracle.Input.field_elements [| msg |])
  in
  Quickcheck.test ~trials:1 gen ~f:(fun (sk0, sk1, msg) ->
      let pk0 = Inner_curve.(scale one sk0) in
      let pk1 = Inner_curve.(scale one sk1) in
      (let sigma1 = Schnorr.sign sk1 msg in
       let%bind sigma1_var =
         exists Schnorr.Signature.typ ~compute:(As_prover.return sigma1)
       and msg_var =
         exists (Schnorr.message_typ ()) ~compute:(As_prover.return msg)
       in
       check_witness [ pk0; pk1 ] msg_var sigma1_var)
      |> Checked.map ~f:As_prover.return
      |> Fn.flip run_and_check () |> Or_error.ok_exn |> snd)

(* test a snapp tx with a 3-party ring *)
let%test_unit "ring-signature snapp tx with 3 parties" =
  let open Transaction_logic.For_tests in
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    (* secret keys of ring participants*)
    let%map ring_member_sks =
      Quickcheck.Generator.list_with_length 3 Private_key.gen
    (* index of the key that will sign the msg *)
    and sign_index = Base_quickcheck.Generator.int_inclusive 0 2
    and test_spec = Test_spec.gen in
    (ring_member_sks, sign_index, test_spec)
  in
  (* set to true to print vk, parties *)
  let debug_mode : bool = false in
  Quickcheck.test ~trials:1 gen
    ~f:(fun (ring_member_sks, sign_index, { init_ledger; specs }) ->
      let ring_member_pks =
        List.map ring_member_sks ~f:Inner_curve.(scale one)
      in
      Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
          Init_ledger.init (module Ledger.Ledger_inner) init_ledger ledger ;
          let spec = List.hd_exn specs in
          let tag, _, (module P), Pickles.Provers.[ ringsig_prover; _ ] =
            Pickles.compile ~cache:Cache_dir.cache
              (module Snapp_statement.Checked)
              (module Snapp_statement)
              ~typ:Snapp_statement.typ
              ~branches:(module Nat.N2)
              ~max_branching:(module Nat.N2) (* You have to put 2 here... *)
              ~name:"ringsig"
              ~constraint_constants:
                (Genesis_constants.Constraint_constants.to_snark_keys_header
                   constraint_constants)
              ~choices:(fun ~self ->
                [ ring_sig_rule ring_member_pks; dummy_rule self ])
          in
          let vk = Pickles.Side_loaded.Verification_key.of_compiled tag in
          ( if debug_mode then
            Binable.to_string (module Side_loaded_verification_key.Stable.V1) vk
            |> Base64.encode_exn ~alphabet:Base64.uri_safe_alphabet
            |> printf "vk:\n%s\n\n" )
          |> fun () ->
          let Transaction_logic.For_tests.Transaction_spec.
                { sender = sender, sender_nonce
                ; receiver = ringsig_account_pk
                ; amount
                ; _
                } =
            spec
          in
          let fee = Amount.of_string "1000000" in
          let vk = With_hash.of_data ~hash_data:Snapp_account.digest_vk vk in
          let total = Option.value_exn (Amount.add fee amount) in
          (let _is_new, _loc =
             let pk = Public_key.compress sender.public_key in
             let id = Account_id.create pk Token_id.default in
             Ledger.get_or_create_account ledger id
               (Account.create id
                  Balance.(Option.value_exn (add_amount zero total)))
             |> Or_error.ok_exn
           in
           let _is_new, loc =
             let id = Account_id.create ringsig_account_pk Token_id.default in
             Ledger.get_or_create_account ledger id
               (Account.create id Balance.(of_int 0))
             |> Or_error.ok_exn
           in
           let a = Ledger.get ledger loc |> Option.value_exn in
           Ledger.set ledger loc
             { a with
               snapp =
                 Some
                   { (Option.value ~default:Snapp_account.default a.snapp) with
                     verification_key = Some vk
                   }
             }) ;
          let fee_payer =
            { Party.Signed.data =
                { body =
                    { pk = sender.public_key |> Public_key.compress
                    ; update = Party.Update.noop
                    ; token_id = Token_id.default
                    ; delta = Amount.Signed.(negate (of_unsigned total))
                    ; events = []
                    ; rollup_events = []
                    ; call_data = Field.zero
                    ; depth = 0
                    }
                ; predicate = sender_nonce
                }
                (* Real signature added in below *)
            ; authorization = Signature.dummy
            }
          in
          let snapp_party_data : Party.Predicated.t =
            { Party.Predicated.Poly.body =
                { pk = ringsig_account_pk
                ; update = Party.Update.noop
                ; token_id = Token_id.default
                ; delta = Amount.Signed.(of_unsigned amount)
                ; events = []
                ; rollup_events = []
                ; call_data = Field.zero
                ; depth = 0
                }
            ; predicate = Full Snapp_predicate.Account.accept
            }
          in
          let protocol_state = Snapp_predicate.Protocol_state.accept in
          let ps =
            Parties.Party_or_stack.of_parties_list
              ~party_depth:(fun (p : Party.Predicated.t) -> p.body.depth)
              [ snapp_party_data ]
            |> Parties.Party_or_stack.accumulate_hashes_predicated
          in
          let other_parties_hash = Parties.Party_or_stack.stack_hash ps in
          let protocol_state_predicate_hash =
            Snapp_predicate.Protocol_state.digest protocol_state
          in
          let transaction : Parties.Transaction_commitment.t =
            Parties.Transaction_commitment.create ~other_parties_hash
              ~protocol_state_predicate_hash
          in
          let at_party = Parties.Party_or_stack.stack_hash ps in
          let tx_statement : Snapp_statement.t = { transaction; at_party } in
          let msg =
            tx_statement |> Snapp_statement.to_field_elements
            |> Random_oracle_input.field_elements
          in
          let signing_sk = List.nth_exn ring_member_sks sign_index in
          let sigma = Schnorr.sign signing_sk msg in
          let handler (Snarky_backendless.Request.With { request; respond }) =
            match request with
            | Sigma ->
                respond @@ Provide sigma
            | _ ->
                respond Unhandled
          in
          let pi : Pickles.Side_loaded.Proof.t =
            (fun () -> ringsig_prover ~handler [] tx_statement)
            |> Async.Thread_safe.block_on_async_exn
          in
          let fee_payer =
            let txn_comm =
              Parties.Transaction_commitment.with_fee_payer transaction
                ~fee_payer_hash:
                  Party.Predicated.(digest (of_signed fee_payer.data))
            in
            { fee_payer with
              authorization =
                Signature_lib.Schnorr.sign sender.private_key
                  (Random_oracle.Input.field txn_comm)
            }
          in
          let parties : Parties.t =
            { fee_payer
            ; other_parties =
                [ { data = snapp_party_data; authorization = Proof pi } ]
            ; protocol_state
            }
          in
          ( if debug_mode then
            (* print fee payer *)
            Party.Signed.to_yojson fee_payer
            |> Yojson.Safe.pretty_to_string
            |> printf "fee_payer:\n%s\n\n"
            |> fun () ->
            (* print other_party data *)
            List.hd_exn parties.other_parties
            |> (fun (p : Party.t) -> Party.Predicated.to_yojson p.data)
            |> Yojson.Safe.pretty_to_string
            |> printf "other_party_data:\n%s\n\n"
            |> fun () ->
            (* print other_party proof *)
            Pickles.Side_loaded.Proof.Stable.V1.sexp_of_t pi
            |> Sexp.to_string |> Base64.encode_exn
            |> printf "other_party_proof:\n%s\n\n"
            |> fun () ->
            (* print protocol_state *)
            Snapp_predicate.Protocol_state.to_yojson protocol_state
            |> Yojson.Safe.pretty_to_string
            |> printf "protocol_state:\n%s\n\n" )
          |> fun () -> apply_parties ledger [ parties ])
      |> fun ((), ()) -> ())
