(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_read_line
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
open Lwt_text
open Lwt_term

type edition_state = Text.t * Text.t
type history = Text.t list
type prompt = Lwt_term.styled_text
type clipboard = Text.t ref

let clipboard = ref ""

exception Interrupt

(* +-----------------------------------------------------------------+
   | Completion                                                      |
   +-----------------------------------------------------------------+ *)

type completion_result = {
  comp_state : edition_state;
  comp_words : Text.t list;
}

type completion = edition_state -> completion_result Lwt.t

let common_prefix a b =
  let lena = String.length a and lenb = String.length b in
  let rec loop i =
    if i = lena || i = lenb || (a.[i] <> b.[i]) then
      String.sub a 0 i
    else
      loop (i + 1)
  in
  loop 0

let lookup word words =
  match List.filter (fun word' -> Text.starts_with word' word) words with
    | [] ->
        ("", [])
    | (head :: tail) as l ->
        (List.fold_left common_prefix head tail, l)

let complete ?(suffix=" ") before word after words =
  match lookup word words with
    | (_, []) ->
        { comp_state = (before ^ word, after); comp_words = [] }
    | (prefix, words) ->
        { comp_state = (before ^ prefix, after);
          comp_words = words }

(* +-----------------------------------------------------------------+
   | Commands                                                        |
   +-----------------------------------------------------------------+ *)

module Command =
struct

  type t =
    | Nop
    | Char of Text.t
    | Backward_delete_char
    | Forward_delete_char
    | Beginning_of_line
    | End_of_line
    | Complete
    | Kill_line
    | Accept_line
    | Backward_delete_word
    | Forward_delete_word
    | History_next
    | History_previous
    | Break
    | Clear_screen
    | Insert
    | Refresh
    | Backward_char
    | Forward_char
    | Set_mark
    | Paste
    | Copy
    | Cut
    | Uppercase
    | Lowercase
    | Capitalize
    | Backward_word
    | Forward_word
    | Complete_left
    | Complete_right
    | Complete_up
    | Complete_down

  let to_string = function
    | Char ch ->
        Printf.sprintf "Char %S" ch
    | Nop ->
        "nop"
    | Backward_delete_char ->
        "backward-delete-char"
    | Forward_delete_char ->
        "forward-delete-char"
    | Beginning_of_line ->
        "beginning-of-line"
    | End_of_line ->
        "end-of-line"
    | Complete ->
        "complete"
    | Kill_line ->
        "kill-line"
    | Accept_line ->
        "accept-line"
    | Backward_delete_word ->
        "backward-delete-word"
    | Forward_delete_word ->
        "forward-delete-word"
    | History_next ->
        "history-next"
    | History_previous ->
        "history-previous"
    | Break ->
        "break"
    | Clear_screen ->
        "clear-screen"
    | Insert ->
        "insert"
    | Refresh ->
        "refresh"
    | Backward_char ->
        "backward-char"
    | Forward_char ->
        "forward-char"
    | Set_mark ->
        "set-mark"
    | Paste ->
        "paste"
    | Copy ->
        "copy"
    | Cut ->
        "cut"
    | Uppercase ->
        "uppercase"
    | Lowercase ->
        "lowercase"
    | Capitalize ->
        "capitalize"
    | Backward_word ->
        "backward-word"
    | Forward_word ->
        "forward-word"
    | Complete_left ->
        "complete-left"
    | Complete_right ->
        "complete-right"
    | Complete_up ->
        "complete-up"
    | Complete_down ->
        "complete-down"

  let of_key = function
    | Key_up -> History_previous
    | Key_down -> History_next
    | Key_left -> Backward_char
    | Key_right -> Forward_char
    | Key_enter -> Accept_line
    | Key_home -> Beginning_of_line
    | Key_end -> End_of_line
    | Key_insert -> Insert
    | Key_backspace -> Backward_delete_char
    | Key_delete -> Forward_delete_char
    | Key_tab -> Complete
    | Key_control '@' -> Set_mark
    | Key_control 'a' -> Beginning_of_line
    | Key_control 'd' -> Break
    | Key_control 'e' -> End_of_line
    | Key_control 'i' -> Complete
    | Key_control 'j' -> Accept_line
    | Key_control 'k' -> Kill_line
    | Key_control 'l' -> Clear_screen
    | Key_control 'm' -> Accept_line
    | Key_control 'n' -> Backward_char
    | Key_control 'p' -> Forward_char
    | Key_control 'r' -> Refresh
    | Key_control 'w' -> Cut
    | Key_control 'y' -> Paste
    | Key_control '?' -> Backward_delete_char
    | Key "\027u" -> Uppercase
    | Key "\027l" -> Lowercase
    | Key "\027c" -> Capitalize
    | Key "\027Oc" | Key "\027[1;5C"-> Forward_word
    | Key "\027Od" | Key "\027[1;5D"-> Backward_word
    | Key ch when Text.length ch = 1 && Text.is_print ch -> Char ch
    | Key "\027\027[A" | Key "\027[1;3A" -> Complete_up
    | Key "\027\027[B" | Key "\027[1;3B" -> Complete_down
    | Key "\027\027[C" | Key "\027[1;3C" -> Complete_right
    | Key "\027\027[D" | Key "\027[1;3D" -> Complete_left
    | Key "\027\n" | Key "\194\141" -> Char "\n"
    | Key "\027w" | Key "\195\183" -> Copy
    | _ -> Nop
end

(* +-----------------------------------------------------------------+
   | Read-line engine                                                |
   +-----------------------------------------------------------------+ *)

module Engine =
struct
  open Command

  type selection_state = {
    sel_text : Text.t;
    sel_mark : Text.pointer;
    sel_cursor : Text.pointer;
  }

  type mode =
    | Edition of edition_state
    | Selection of selection_state

  type state = {
    mode : mode;
    history : history * history;
  }

  let init history = {
    mode = Edition("", "");
    history = (history, []);
  }

  let all_input state = match state.mode with
    | Edition(before, after) -> before ^ after
    | Selection sel -> sel.sel_text

  let edition_state state = match state.mode with
    | Edition(before, after) -> (before, after)
    | Selection sel -> (Text.chunk (Text.pointer_l sel.sel_text) sel.sel_cursor,
                        Text.chunk sel.sel_cursor (Text.pointer_r sel.sel_text))

  (* Reset the mode to the edition mode: *)
  let reset state = match state.mode with
    | Edition _ ->
        state
    | Selection sel ->
        { state with mode = Edition(Text.chunk (Text.pointer_l sel.sel_text) sel.sel_cursor,
                                    Text.chunk sel.sel_cursor (Text.pointer_r sel.sel_text)) }

  let split_first_word text =
    let rec find_last ptr =
      match Text.next ptr with
        | Some(ch, ptr) when Text.is_alnum ch ->
            find_last ptr
        | _ ->
            ptr
    in
    let rec find_first ptr =
      match Text.next ptr with
        | Some(ch, ptr') ->
            if Text.is_alnum ch then
              let ptr' = find_last ptr' in
              (Text.chunk (Text.pointer_l text) ptr,
               Text.chunk ptr ptr',
               Text.chunk ptr' (Text.pointer_r text))
            else
              find_first ptr'
        | None ->
            (text, "", "")
    in
    find_first (Text.pointer_l text)

  let split_last_word text =
    let rec find_first ptr =
      match Text.prev ptr with
        | Some(ch, ptr) when Text.is_alnum ch ->
            find_first ptr
        | _ ->
            ptr
    in
    let rec find_last ptr =
      match Text.prev ptr with
        | Some(ch, ptr') ->
            if Text.is_alnum ch then
              let ptr' = find_first ptr' in
              (Text.chunk (Text.pointer_l text) ptr',
               Text.chunk ptr' ptr,
               Text.chunk ptr (Text.pointer_r text))
            else
              find_last ptr'
        | None ->
            (text, "", "")
    in
    find_last (Text.pointer_r text)

  let rec update state ?(clipboard=clipboard) cmd =
    (* Helpers for updating the mode state only: *)
    let edition st = { state with mode = Edition st } and selection st = { state with mode = Selection st } in
    match state.mode with
      | Selection sel ->
          (* Change the cursor position: *)
          let maybe_set_cursor = function
            | Some(_, ptr) ->
                selection { sel with sel_cursor = ptr }
            | None ->
                state
          in

          begin match cmd with
            | Nop ->
                state

            | Forward_char ->
                maybe_set_cursor (Text.next sel.sel_cursor)

            | Backward_char ->
                maybe_set_cursor (Text.prev sel.sel_cursor)

            | Beginning_of_line ->
                selection { sel with sel_cursor =  Text.pointer_l sel.sel_text }

            | End_of_line ->
                selection { sel with sel_cursor =  Text.pointer_r sel.sel_text }

            | Copy ->
                let a = min sel.sel_cursor sel.sel_mark and b = max sel.sel_cursor sel.sel_mark in
                clipboard := Text.chunk a b;
                edition (Text.chunk (Text.pointer_l sel.sel_text) sel.sel_cursor,
                         Text.chunk sel.sel_cursor (Text.pointer_r sel.sel_text))

            | Cut ->
                let a = min sel.sel_cursor sel.sel_mark and b = max sel.sel_cursor sel.sel_mark in
                clipboard := Text.chunk a b;
                edition (Text.chunk (Text.pointer_l sel.sel_text) a,
                         Text.chunk b (Text.pointer_r sel.sel_text))

            | cmd ->
                (* If the user sent another command, reset the mode to
                   edition and process the command: *)
                update (reset state) ~clipboard cmd
          end

      | Edition(before, after) ->
          begin match cmd with
            | Char ch ->
                edition (before ^ ch, after)

            | Set_mark ->
                let txt = before ^ after in
                let ptr = Text.pointer_at txt (Text.length before) in
                selection { sel_text = txt;
                            sel_mark = ptr;
                            sel_cursor = ptr }

            | Paste ->
                edition (before ^ !clipboard, after)

            | Backward_delete_char ->
                edition (Text.rchop before, after)

            | Forward_delete_char ->
                edition (before, Text.lchop after)

            | Beginning_of_line ->
                edition ("", before ^ after)

            | End_of_line ->
                edition (before ^ after, "")

            | Kill_line ->
                edition (before, "")

            | History_previous ->
                begin match state.history with
                  | ([], _) ->
                      state
                  | (line :: hist_before, hist_after) ->
                      { mode = Edition(line, "");
                        history = (hist_before, (before ^ after) :: hist_after) }
                end

            | History_next ->
                begin match state.history with
                  | (_, []) ->
                      state
                  | (hist_before, line :: hist_after) ->
                      { mode = Edition(line, "");
                        history = ((before ^ after) :: hist_before, hist_after) }
                end

            | Backward_char ->
                if before = "" then
                  state
                else
                  edition (Text.rchop before,
                           Text.get before (-1) ^ after)

            | Forward_char ->
                if after = "" then
                  state
                else
                  edition (before ^ (Text.get after 0),
                           Text.lchop after)

            | Uppercase ->
                let a, b, c = split_first_word after in
                edition (before ^ a ^ Text.upper b, c)

            | Lowercase ->
                let a, b, c = split_first_word after in
                edition (before ^ a ^ Text.lower b, c)

            | Capitalize ->
                let a, b, c = split_first_word after in
                edition (before ^ a ^ Text.capitalize (Text.lower b), c)

            | Backward_word ->
                let a, b, c = split_last_word before in
                edition (a, b ^ c ^ after)

            | Forward_word ->
                let a, b, c = split_first_word after in
                edition (before ^ a ^ b, c)

            | _ ->
                state
          end
end

(* +-----------------------------------------------------------------+
   | Rendering                                                       |
   +-----------------------------------------------------------------+ *)

let rec repeat f n =
  if n <= 0 then
    return ()
  else
    lwt () = f () in
    repeat f (n - 1)


let print_words oc screen_width words = match List.filter ((<>) "") words with
  | [] ->
      return ()
  | words ->
      let max_width = List.fold_left (fun x word -> max x (Text.length word)) 0 words + 1 in
      let count = List.length words in
      let columns = max 1 (screen_width / max_width) in
      let lines =
        if count < columns then
          1
        else
          let l = count / columns in
          if columns mod count = 0 then l else l + 1
      in
      let column_width = screen_width / columns in
      let m = Array.make_matrix lines columns "" in
      let rec fill_display line column = function
        | [] ->
            ()
        | word :: words ->
            m.(line).(column) <- word;
            let line = line + 1 in
            if line < lines then
              fill_display line column words
            else
              fill_display 0 (column + 1) words
      in
      fill_display 0 0 words;
      for_lwt line = 0 to lines - 1 do
        lwt () =
          for_lwt column = 0 to columns - 1 do
            let word = m.(line).(column) in
            lwt () = write oc word in
            let len = Text.length word in
            if len < column_width then
              repeat (fun () -> write_char oc " ") (column_width - len)
            else
              return ()
          done
        in
        write_char oc "\n"
      done

module Terminal =
struct
  open Engine
  open Command

  type state = {
    length : int;
    (* Length in characters of the complete printed text: the prompt,
       the input before the cursor and the input after the cursor.*)
    height_before : int;
    (* The height of the complete text printed before the cursor: the
       prompt and the input before the cursor. *)
  }

  let init = { length = 0; height_before = 0 }

  (* Go-up by [n] lines then to the beginning of the line. Normally
     "\027[nF" does exactly this but for some terminal 1 need to be
     added... By the way we can relly on the fact that all terminal
     react the same way to "\027[F" which is to go to the beginning of
     the previous line: *)
  let rec beginning_of_line = function
    | 0 ->
        write_char stdout "\r"
    | 1 ->
        write stdout "\027[F"
    | n ->
        lwt () = write stdout "\027[F" in
        beginning_of_line (n - 1)

  (* Replace "\n" by padding to the end of line in a styled text.

     For example with 5 columns, ["toto\ntiti"] becomes ["toto titi"].

     The goal of that is to erase all previous characters after end of
     lines. *)
  let prepare_for_display columns styled_text =
    let rec loop len = function
      | [] ->
          []
      | Text text :: l ->
          let buf = Buffer.create (Text.length text) in
          let len = Text.fold
            (fun ch len -> match ch with
               | "\n" ->
                   let padding = columns - (len mod columns) in
                   for i = 1 to padding do
                     Buffer.add_char buf ' '
                   done;
                   len + padding
               | ch ->
                   Buffer.add_string buf ch;
                   len + 1) text len in
          Text(Buffer.contents buf) :: loop len l
      | style :: l ->
          style :: loop len l
    in
    loop 0 styled_text

  (* Compute the number of row taken by a text given a number of
     columns: *)
  let compute_height columns len =
    if len = 0 then
      0
    else
      (len - 1) / columns

  let make_completion columns words =
    let result = String.make columns ' ' in
    let rec aux i = function
      | [] ->
          result
      | word :: words ->
          let len = Text.length word in
          if i + len >= columns + 1 then begin
            String.blit word 0 result i (columns - i);
            result
          end else begin
            String.blit word 0 result i len;
            aux (i + len + 1) words
          end
    in
    aux 0 words

  (* Render the current state on the terminal, and returns the new
     terminal rendering state: *)
  let draw ?(map_text=fun x -> x) ?completion render_state engine_state prompt =
    (* Text before and after the cursor, according to the current mode: *)
    let before, after = match engine_state.mode with
      | Edition(before, after) ->
          ([Text(map_text before)], [Text(map_text after)])
      | Selection sel ->
          let a = min sel.sel_cursor sel.sel_mark and b = max sel.sel_cursor sel.sel_mark in
          let part_before = [Text(map_text (Text.chunk (Text.pointer_l sel.sel_text) a))]
          and part_selected = [Underlined; Text(map_text (Text.chunk a b)); Reset]
          and part_after = [Text(map_text (Text.chunk (Text.pointer_r sel.sel_text) b))] in
          if sel.sel_cursor < sel.sel_mark then
            (part_before, part_selected @ part_after)
          else
            (part_before @ part_selected, part_after)
    in

    let columns = React.S.value Lwt_term.columns in

    (* All the text printed before the cursor: *)
    let printed_before = prepare_for_display columns
      (prompt @ [Reset] @ before) in

    (* The total printed text: *)
    let printed_total = prepare_for_display columns
      (prompt @ [Reset] @ before @ after @ (match completion with
                                              | None ->
                                                  []
                                              | Some words ->
                                                  [Foreground lblue; Text "\n";
                                                   Text(Text.repeat columns "─");
                                                   Text(make_completion columns words)])) in

    (* The new rendering state: *)
    let new_render_state = {
      height_before = compute_height columns (styled_length printed_before);
      length = styled_length printed_total;
    } in

    (* The total printed text with any needed spaces after to erase all
       previous text: *)
    let printed_total_erase = printed_total @ [Text(String.make (max 0 (render_state.length - styled_length printed_total)) ' ')] in

    (* Go back by the number of rows of the previous text: *)
    lwt () = beginning_of_line render_state.height_before in

    (* Prints and erase everything: *)
    lwt () = printc printed_total_erase in

    (* Go back again to the beginning of printed text: *)
    lwt () = beginning_of_line (compute_height columns (styled_length printed_total_erase)) in

    (* Prints again the text before the cursor, to put the cursor at the
       right place: *)
    lwt () = printc printed_before in

    (* Print a newline if we are at the end of a line; otherwise the
       cursor will stay on the last character of the line *)
    if (styled_length printed_before) mod columns = 0 then
      lwt () = print "\n" in
      return { new_render_state with height_before = new_render_state.height_before + 1 }
    else
      return new_render_state

  let last_draw ?(map_text=fun x -> x) ?(completion=false) render_state engine_state prompt =
    let columns = React.S.value Lwt_term.columns in
    lwt () = beginning_of_line render_state.height_before in
    lwt () = printlc (prepare_for_display
                        columns
                        (prompt @ [Reset; Text(map_text(all_input engine_state))] @
                           (match completion with
                              | false ->
                                  []
                              | true ->
                                  [Text "\n\n\n"]))) in
    if completion then
      beginning_of_line 2
    else
      return ()
end

(* +-----------------------------------------------------------------+
   | High-level functions                                            |
   +-----------------------------------------------------------------+ *)

open Command

let read_command () = read_key () >|= Command.of_key

let read_line ?(history=[]) ?(complete=fun state -> return { comp_state = state; comp_words = [] })
    ?(clipboard=clipboard) ?(dynamic=false) prompt =
  let rec process_command render_state engine_state = function
    | Clear_screen ->
        lwt () = clear_screen () in
        redraw Terminal.init engine_state

    | Refresh ->
        redraw render_state engine_state

    | Accept_line ->
        lwt () = Terminal.last_draw ~completion:dynamic render_state engine_state prompt in
        return (Engine.all_input engine_state)

    | Break ->
        lwt () = Terminal.last_draw ~completion:dynamic render_state engine_state prompt in
        fail Interrupt

    | Complete ->
        if dynamic then  begin
          let engine_state = Engine.reset engine_state in
          (* Let the completion and user input run in parallel: *)
          select [complete (Engine.edition_state engine_state) >|= (fun c -> `Completion c);
                  read_command () >|= (fun c -> `Command c)]
          >>= function
            | `Command command ->
                process_command render_state engine_state command
            | `Completion{ comp_words = [] } ->
                loop render_state engine_state
            | `Completion{ comp_state = (before, after); comp_words = word :: words } ->
                let engine_state = { engine_state with Engine.mode = Engine.Edition(before, after) } in
                redraw render_state engine_state
        end else begin
          let engine_state = Engine.reset engine_state in
          select [complete (Engine.edition_state engine_state) >|= (fun c -> `Completion c);
                  read_command () >|= (fun c -> `Command c)]
          >>= function
            | `Command command ->
                process_command render_state engine_state command
            | `Completion{ comp_state = (before, after); comp_words = [_] } ->
                let engine_state = { engine_state with Engine.mode = Engine.Edition(before, after) } in
                lwt render_state = Terminal.draw render_state engine_state prompt in
                loop render_state engine_state
            | `Completion{ comp_state = (before, after); comp_words = words } ->
                let engine_state = { engine_state with Engine.mode = Engine.Edition(before, after) } in
                lwt () = write_char stdout "\n" in
                lwt () = print_words stdout (React.S.value Lwt_term.columns) words in
                lwt () = write_char stdout "\n" in
                lwt render_state = Terminal.draw render_state engine_state prompt in
                loop render_state engine_state
        end
    | cmd ->
        let new_state = Engine.update engine_state ~clipboard cmd in
        (* Do not redraw if not needed: *)
        if new_state <> engine_state then
          redraw render_state new_state
        else
          loop render_state new_state

  and redraw render_state engine_state =
    lwt completion = match dynamic with
      | false ->
          return None
      | true ->
          lwt result = complete (Engine.edition_state engine_state) in
          return (Some result.comp_words)
    in
    lwt render_state = Terminal.draw ?completion render_state engine_state prompt in
    loop render_state engine_state

  and loop render_state engine_state =
    read_command () >>= process_command render_state engine_state
  in
  if Unix.isatty Unix.stdin && Unix.isatty Unix.stdout then
    with_raw_mode (fun _ -> redraw Terminal.init (Engine.init history))
  else
    lwt () = write stdout (strip_styles prompt) in
    Lwt_text.read_line stdin

let read_password ?(clipboard=clipboard) ?(style=`text "*") prompt =
  (* Choose a mapping text function according to style: *)
  let map_text = match style with
    | `text ch -> (fun txt -> Text.map (fun _ -> ch) txt)
    | `clear -> (fun x -> x)
    | `empty -> (fun _ -> "") in
  let rec process_command render_state engine_state = function
    | Clear_screen ->
        lwt () = clear_screen () in
        redraw Terminal.init engine_state

    | Refresh ->
        redraw render_state engine_state

    | Accept_line ->
        lwt () = Terminal.last_draw ~map_text render_state engine_state prompt in
        return (Engine.all_input engine_state)

    | Break ->
        lwt () = Terminal.last_draw ~map_text render_state engine_state prompt in
        fail Interrupt

    | cmd ->
        let new_state = Engine.update engine_state ~clipboard cmd in
        if new_state <> engine_state then
          redraw render_state new_state
        else
          loop render_state new_state

  and redraw render_state engine_state =
    lwt render_state = Terminal.draw ~map_text render_state engine_state prompt in
    loop render_state engine_state

  and loop render_state engine_state =
    read_command () >>= process_command render_state engine_state

  in
  if not (Unix.isatty Unix.stdin && Unix.isatty Unix.stdout) then
    fail (Failure "Lwt_read_line.read_password: not running in a terminal")
  else
    with_raw_mode (fun _ ->  Lwt_stream.junk_old standard_input >> redraw Terminal.init (Engine.init []))

let read_keyword ?(history=[]) ?(case_sensitive=false) ?(dynamic=false) prompt keywords =
  let compare = if case_sensitive then Text.compare else Text.icompare in
  let rec assoc key = function
    | [] -> None
    | (key', value) :: l ->
        if compare key key' = 0 then
          Some value
        else
          assoc key l
  in
  let rec process_command render_state engine_state = function
    | Clear_screen ->
        lwt () = clear_screen () in
        redraw Terminal.init engine_state

    | Refresh ->
        redraw render_state engine_state

    | Accept_line ->
        begin match assoc (Engine.all_input engine_state) keywords with
          | Some value ->
              lwt () = Terminal.last_draw ~completion:dynamic render_state engine_state prompt in
              return value
          | None ->
              loop render_state engine_state
        end

    | Break ->
        lwt () = Terminal.last_draw ~completion:dynamic render_state engine_state prompt in
        fail Interrupt

    | Complete ->
        let engine_state = Engine.reset engine_state in
        let txt, _ = Engine.edition_state engine_state in
        begin match List.filter (fun (kwd, _) -> Text.starts_with kwd txt) keywords with
          | [(kwd, _)] ->
              redraw render_state { engine_state with Engine.mode = Engine.Edition(kwd, "") }
          | _ ->
              loop render_state engine_state
        end

    | cmd ->
        let new_state = Engine.update engine_state ~clipboard cmd in
        if new_state <> engine_state then
          redraw render_state new_state
        else
          loop render_state new_state

  and redraw render_state engine_state =
    let completion = match dynamic with
      | false ->
          None
      | true ->
          let txt, _ = Engine.edition_state engine_state in
          Some(List.map fst (List.filter (fun (kwd, _) -> Text.starts_with kwd txt) keywords))
    in
    lwt render_state = Terminal.draw ?completion render_state engine_state prompt in
    loop render_state engine_state

  and loop render_state engine_state =
    read_command () >>= process_command render_state engine_state
  in
  if Unix.isatty Unix.stdin && Unix.isatty Unix.stdout then
    with_raw_mode (fun _ -> redraw Terminal.init (Engine.init history))
  else
    lwt _ = write stdout (strip_styles prompt) in
    lwt txt = Lwt_text.read_line stdin in
    match assoc txt keywords with
      | Some value ->
          return value
      | None ->
          fail (Failure "Lwt_read_line.read_keyword: invalid input")

let read_yes_no ?history ?dynamic prompt =
  read_keyword ?history ?dynamic prompt [("yes", true); ("y", true); ("no", false); ("n", false)]

(* +-----------------------------------------------------------------+
   | History                                                         |
   +-----------------------------------------------------------------+ *)

let add_entry line history =
  if Text.strip line = "" then
    history
  else
    if (match history with [] -> false | x :: _ -> x = line) then
      history
    else
      line :: history

let save_history name history =
  with_file ~mode:Lwt_io.output name
    (fun oc ->
       Lwt_util.iter_serial
         (fun line -> write oc line >> write_char oc "\000")
         history)

let load_line ic =
  let buf = Buffer.create 42 in
  let rec loop () =
    read_char_opt ic >>= function
      | None | Some "\000" ->
          return (`Line(Buffer.contents buf))
      | Some ch ->
          Buffer.add_string buf ch;
          loop ()
  in
  read_char_opt ic >>= function
    | None -> return `End_of_file
    | Some "\000" -> return `Empty
    | Some ch -> Buffer.add_string buf ch; loop ()

let rec load_lines ic =
  load_line ic >>= function
    | `Line line ->
        lwt lines = load_lines ic in
        return (line :: lines)
    | `Empty ->
        load_lines ic
    | `End_of_file ->
        return []

let load_history name =
  match try Some(open_file ~mode:Lwt_io.input name) with _ -> None with
    | Some ic ->
        try_lwt
          load_lines ic
        finally
          close ic
    | None ->
        return []
