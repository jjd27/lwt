(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_signal
 * Copyright (C) 2009 Jérémie Dimino
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

open Lwt

(* +-----------------------------------------------------------------+
   | Notifiers                                                       |
   +-----------------------------------------------------------------+ *)

type notifier = unit React.signal Lwt_sequence.node

let notifiers = Lwt_sequence.create ()

let disable n =
  Lwt_sequence.remove n;
  React.S.stop (Lwt_sequence.get n)

let notify f signal =
  Lwt_sequence.add_l (React.S.map f signal) notifiers

let notify_p f signal =
  Lwt_sequence.add_l (React.S.map (fun x -> Lwt.ignore_result (f x)) signal) notifiers

let notify_s f signal =
  let mutex = Lwt_mutex.create () in
  Lwt_sequence.add_l (React.S.map (fun x -> Lwt.ignore_result (Lwt_mutex.with_lock mutex (fun () -> f x))) signal) notifiers

let always_notify f signal =
  ignore (notify f signal)

let always_notify_p f signal =
  ignore (notify_p f signal)

let always_notify_s f signal =
  ignore (notify_s f signal)

(* +-----------------------------------------------------------------+
   | Lwt-specific utilities                                          |
   +-----------------------------------------------------------------+ *)

let finalise f _ = f ()

let with_finaliser f signal =
  let r = ref () in
  Gc.finalise (finalise f) r;
  React.S.map (fun x -> ignore r; x) signal

let limit ?eq f signal =
  let event1, push1 = React.E.create () in
  let sleep = ref (f ()) and stop = ref None in
  let event2 =
    React.E.filter
      (fun x ->
         if state !sleep <> Sleep then begin
           sleep := f ();
           true
         end else begin
           let _ =
             let waiter, wakener = wait () in
             let () =
               match !stop with
                 | Some wakener' ->
                     stop := Some wakener;
                     wakeup_exn wakener' Exit
                 | None ->
                     stop := Some wakener
             in
             lwt () = !sleep <?> waiter in
             stop := None;
             sleep := f ();
             push1 x;
             return ()
           in
           false
         end)
      (React.S.changes signal)
  in
  React.S.hold ?eq (React.S.value signal) (React.E.select [event1; event2])

(* +-----------------------------------------------------------------+
   | Signal transofrmations                                          |
   +-----------------------------------------------------------------+ *)

let map_s ?eq f initial signal =
  React.S.hold ?eq initial (Lwt_event.map_s f (React.S.changes signal))
