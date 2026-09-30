import categories
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import items.{
  type Item, Item, merge_item, parse_scanned_line, reader, sort_items, writer,
}
import lustre
import lustre/effect
import model.{
  type Message, type Model, Connected, Connecting, ConnectionStatusChanged,
  Disconnected, Model, Noop, RemoteItemsReceived, UserAddedItem,
  UserAskedToDeleteList, UserCancelledDeleteList, UserChangedDraftAmount,
  UserChangedDraftCategory, UserChangedDraftName, UserChangedSwitchInput,
  UserClickedCopyLink, UserClickedItem, UserClickedNativeShare,
  UserClosedShareModal, UserClosedSwitchModal, UserConfirmedDeleteList,
  UserConfirmedEdit, UserConfirmedSwitchRoom, UserDeletedItem,
  UserGenerateRandomRoom, UserOpenedShareModal, UserOpenedSwitchModal,
  UserScanFailed, UserScannedText, UserSelectedImage, UserToggledItem,
  UserToggledSection,
}
import varasto
import view as app_view

pub fn main() {
  let app =
    lustre.application(init, update, fn(model) {
      app_view.view(model, get_share_link(model.room_id))
    })
  let assert Ok(_) = lustre.start(app, "#app", 0)
  Nil
}

// =============================================================================
// FFI External Bindings
// =============================================================================

@external(javascript, "./frigo_ffi.mjs", "get_file_from_input")
fn get_file_from_input(event: dynamic.Dynamic) -> dynamic.Dynamic

@external(javascript, "./frigo_ffi.mjs", "is_null_file")
fn is_null_file(file: dynamic.Dynamic) -> Bool

@external(javascript, "./frigo_ffi.mjs", "scan_image")
fn do_scan_image(
  file: dynamic.Dynamic,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./frigo_ffi.mjs", "get_active_room_id")
fn get_active_room_id() -> String

@external(javascript, "./frigo_ffi.mjs", "get_access_token")
fn get_access_token(room_id: String) -> String

@external(javascript, "./frigo_ffi.mjs", "set_active_room_id")
fn set_active_room_id(room_id: String, access_token: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "sanitize_room_id")
fn sanitize_room_id(room_id: String) -> String

@external(javascript, "./frigo_ffi.mjs", "random_room_id")
fn random_room_id() -> String

@external(javascript, "./frigo_ffi.mjs", "start_sync")
fn do_start_sync(
  room_id: String,
  access_token: String,
  on_sync: fn(dynamic.Dynamic) -> Nil,
  on_status: fn(Bool) -> Nil,
) -> Nil

@external(javascript, "./frigo_ffi.mjs", "broadcast_items_json")
fn broadcast_items_json(json_string: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "broadcast_delta_json")
fn broadcast_delta_json(json_string: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "share_room_link")
fn share_room_link(room_id: String) -> Bool

@external(javascript, "./frigo_ffi.mjs", "copy_to_clipboard")
fn copy_to_clipboard(text: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "get_share_link")
fn get_share_link(room_id: String) -> String

@external(javascript, "./frigo_ffi.mjs", "render_qr_code")
fn render_qr_code(element_id: String, text: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "enable_swipe_to_delete")
fn enable_swipe_to_delete(on_swipe: fn(String) -> Nil) -> Nil

// =============================================================================
// Application helpers
// =============================================================================

fn load_room_items(
  storage: varasto.TypedStorage(List(Item)),
  room_id: String,
) -> List(Item) {
  varasto.get(storage, "items_" <> room_id)
  |> result.unwrap([])
}

fn persist_and_broadcast_effect(
  storage: varasto.TypedStorage(List(Item)),
  room_id: String,
  items: List(Item),
) -> effect.Effect(Message) {
  effect.from(fn(_) {
    let _ = varasto.set(storage, "items_" <> room_id, items)
    broadcast_items_json(json.to_string(writer(items)))
  })
}

fn save_delta(
  model: Model,
  items: List(Item),
  delta: String,
) -> #(Model, effect.Effect(Message)) {
  let sorted = sort_items(items)
  #(
    Model(..model, items: sorted),
    effect.from(fn(_) {
      let _ =
        varasto.set(model.items_storage, "items_" <> model.room_id, sorted)
      broadcast_delta_json(delta)
    }),
  )
}

/// Sort, store in the model, persist locally and broadcast.
fn save(model: Model, items: List(Item)) -> #(Model, effect.Effect(Message)) {
  let sorted = sort_items(items)
  #(
    Model(..model, items: sorted),
    persist_and_broadcast_effect(model.items_storage, model.room_id, sorted),
  )
}

fn start_sync_effect(room_id: String) -> effect.Effect(Message) {
  effect.from(fn(dispatch) {
    do_start_sync(
      room_id,
      get_access_token(room_id),
      fn(raw) { dispatch(RemoteItemsReceived(raw)) },
      fn(status) { dispatch(ConnectionStatusChanged(status)) },
    )
  })
}

// =============================================================================
// Update Loop
// =============================================================================

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case message {
    Noop -> #(model, effect.none())

    // --- Items ---------------------------------------------------------------
    UserAddedItem(form_item) -> {
      let name =
        list.key_find(form_item, "input_form")
        |> result.unwrap("")
        |> string.trim
        |> string.capitalise

      let count =
        list.key_find(form_item, "input_count")
        |> result.try(int.parse)
        |> result.unwrap(1)
        |> int.max(1)

      let selected_category =
        list.key_find(form_item, "input_category")
        |> result.unwrap("")

      let category = case selected_category {
        "" -> categories.infer_category(name)
        value -> value
      }

      case name {
        "" -> #(model, effect.none())
        _ -> {
          let updated = merge_item(model.items, name, count, category)
          let assert Ok(changed) =
            list.find(updated, fn(item) { item.name == name })
          let operation = case
            list.any(model.items, fn(item) { item.name == name })
          {
            True -> "item_updated"
            False -> "item_added"
          }
          save_delta(
            model,
            updated,
            json.object([
              #("type", json.string(operation)),
              #(
                "item",
                json.object([
                  #("id", json.string(changed.id)),
                  #("name", json.string(changed.name)),
                  #("number", json.int(changed.amount)),
                  #("checked", json.bool(changed.checked)),
                  #("category", json.string(changed.category)),
                ]),
              ),
            ])
              |> json.to_string,
          )
        }
      }
    }

    UserToggledItem(id) -> {
      let updated =
        list.map(model.items, fn(item) {
          case item.id == id {
            True -> Item(..item, checked: !item.checked)
            False -> item
          }
        })
      let assert Ok(changed) = list.find(updated, fn(item) { item.id == id })
      save_delta(
        model,
        updated,
        json.object([
          #("type", json.string("item_updated")),
          #(
            "item",
            json.object([
              #("id", json.string(changed.id)),
              #("name", json.string(changed.name)),
              #("number", json.int(changed.amount)),
              #("checked", json.bool(changed.checked)),
              #("category", json.string(changed.category)),
            ]),
          ),
        ])
          |> json.to_string,
      )
    }

    UserDeletedItem(id) ->
      save_delta(
        model,
        list.filter(model.items, fn(item) { item.id != id }),
        json.object([
          #("type", json.string("item_deleted")),
          #("id", json.string(id)),
        ])
          |> json.to_string,
      )

    // --- Clear list ----------------------------------------------------------
    UserAskedToDeleteList -> #(
      Model(..model, confirm_delete_list: True),
      effect.none(),
    )

    UserCancelledDeleteList -> #(
      Model(..model, confirm_delete_list: False),
      effect.none(),
    )

    UserConfirmedDeleteList -> {
      let #(m, eff) = save(model, [])
      #(Model(..m, confirm_delete_list: False), eff)
    }

    // --- Inline editing ------------------------------------------------------
    UserClickedItem(id, name, amount, category) -> #(
      Model(
        ..model,
        editing: Some(id),
        draft_name: name,
        draft_amount: int.to_string(amount),
        draft_category: category,
      ),
      effect.none(),
    )

    UserChangedDraftName(value) -> #(
      Model(..model, draft_name: value),
      effect.none(),
    )

    UserChangedDraftAmount(value) -> #(
      Model(..model, draft_amount: value),
      effect.none(),
    )

    UserChangedDraftCategory(value) -> #(
      Model(..model, draft_category: value),
      effect.none(),
    )

    UserConfirmedEdit ->
      case model.editing {
        None -> #(model, effect.none())
        Some(original_id) -> {
          let new_name = string.capitalise(string.trim(model.draft_name))
          let original =
            list.find(model.items, fn(item) { item.id == original_id })

          case new_name, int.parse(model.draft_amount), original {
            "", _, _ | _, Error(_), _ | _, _, Error(_) -> #(
              Model(..model, editing: None),
              effect.none(),
            )
            _, Ok(new_amount), Ok(original_item) -> {
              let others =
                list.filter(model.items, fn(item) { item.id != original_id })

              let updated = case
                list.find(others, fn(item) { item.name == new_name })
              {
                Ok(existing) -> [
                  Item(
                    existing.id,
                    new_name,
                    existing.amount + new_amount,
                    False,
                    model.draft_category,
                  ),
                  ..list.filter(others, fn(item) { item.name != new_name })
                ]
                Error(_) -> [
                  Item(
                    original_item.id,
                    name: new_name,
                    amount: new_amount,
                    checked: original_item.checked,
                    category: model.draft_category,
                  ),
                  ..others
                ]
              }

              let #(m, eff) = save(model, updated)
              #(Model(..m, editing: None), eff)
            }
          }
        }
      }

    // --- Sections ------------------------------------------------------------
    UserToggledSection(cat) -> {
      let is_collapsed = list.contains(model.collapsed_sections, cat)
      let new_collapsed = case is_collapsed {
        True -> list.filter(model.collapsed_sections, fn(c) { c != cat })
        False -> [cat, ..model.collapsed_sections]
      }
      #(Model(..model, collapsed_sections: new_collapsed), effect.none())
    }

    // --- OCR -----------------------------------------------------------------
    UserSelectedImage(event) -> {
      let file = get_file_from_input(event)
      case is_null_file(file) {
        True -> #(model, effect.none())
        False -> #(
          Model(..model, scanning: True, ocr_error: None),
          effect.from(fn(dispatch) {
            do_scan_image(
              file,
              fn(text) { dispatch(UserScannedText(text)) },
              fn(error) { dispatch(UserScanFailed(error)) },
            )
          }),
        )
      }
    }

    UserScannedText(text) -> {
      let updated =
        text
        |> string.split("\n")
        |> list.map(string.trim)
        |> list.filter(fn(l) { l != "" })
        |> list.map(parse_scanned_line)
        |> list.filter(fn(pair) { pair.0 != "" })
        |> list.fold(model.items, fn(acc, pair) {
          let category = categories.infer_category(pair.0)
          merge_item(acc, pair.0, pair.1, category)
        })

      let #(m, eff) = save(model, updated)
      #(Model(..m, scanning: False, ocr_error: None), eff)
    }

    UserScanFailed(error) -> #(
      Model(..model, scanning: False, ocr_error: Some(error)),
      effect.none(),
    )

    // --- Real-time sync ------------------------------------------------------
    RemoteItemsReceived(raw) ->
      case decode.run(raw, reader()) {
        Ok(remote_items) -> {
          let sorted = sort_items(remote_items)
          #(
            Model(..model, items: sorted),
            effect.from(fn(_) {
              let _ =
                varasto.set(
                  model.items_storage,
                  "items_" <> model.room_id,
                  sorted,
                )
              Nil
            }),
          )
        }
        Error(_) -> #(model, effect.none())
      }

    ConnectionStatusChanged(is_connected) -> #(
      Model(..model, connection_status: case is_connected {
        True -> Connected
        False -> Disconnected
      }),
      effect.none(),
    )

    // --- Share modal ---------------------------------------------------------
    UserOpenedShareModal -> {
      let link = get_share_link(model.room_id)
      #(
        Model(..model, show_share_modal: True),
        effect.from(fn(_) { render_qr_code("share-qr-code", link) }),
      )
    }

    UserClosedShareModal -> #(
      Model(..model, show_share_modal: False, copied_toast: False),
      effect.none(),
    )

    UserClickedNativeShare -> #(
      model,
      effect.from(fn(_) {
        let _ = share_room_link(model.room_id)
        Nil
      }),
    )

    UserClickedCopyLink -> #(
      Model(..model, copied_toast: True),
      effect.from(fn(_) { copy_to_clipboard(get_share_link(model.room_id)) }),
    )

    // --- Room switching ------------------------------------------------------
    UserOpenedSwitchModal -> #(
      Model(..model, show_switch_modal: True, switch_room_input: model.room_id),
      effect.none(),
    )

    UserClosedSwitchModal -> #(
      Model(..model, show_switch_modal: False),
      effect.none(),
    )

    UserChangedSwitchInput(value) -> #(
      Model(..model, switch_room_input: value),
      effect.none(),
    )

    UserGenerateRandomRoom -> #(
      Model(..model, switch_room_input: random_room_id()),
      effect.none(),
    )

    UserConfirmedSwitchRoom ->
      case sanitize_room_id(model.switch_room_input) {
        "" -> #(model, effect.none())
        room -> #(
          Model(
            ..model,
            room_id: room,
            items: load_room_items(model.items_storage, room),
            show_switch_modal: False,
            connection_status: Connecting,
          ),
          effect.batch([
            effect.from(fn(_) {
              set_active_room_id(room, get_access_token(room))
            }),
            start_sync_effect(room),
          ]),
        )
      }
  }
}

// =============================================================================
// Initialization
// =============================================================================

fn init(_initial: Int) -> #(Model, effect.Effect(Message)) {
  let assert Ok(local) = varasto.local()
  let storage = varasto.new(local, reader(), writer)
  let room = get_active_room_id()

  #(
    Model(
      items_storage: storage,
      items: load_room_items(storage, room),
      scanning: False,
      editing: None,
      confirm_delete_list: False,
      draft_name: "",
      draft_amount: "",
      draft_category: "📦 Otros",
      collapsed_sections: [],
      room_id: room,
      connection_status: Connecting,
      ocr_error: None,
      show_share_modal: False,
      show_switch_modal: False,
      switch_room_input: "",
      copied_toast: False,
    ),
    effect.batch([
      effect.from(fn(dispatch) {
        enable_swipe_to_delete(fn(id) { dispatch(UserDeletedItem(id)) })
      }),
      start_sync_effect(room),
    ]),
  )
}
