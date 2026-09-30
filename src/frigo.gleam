import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import varasto

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", 0)
  Nil
}

pub type Item {
  Item(name: String, amount: Int, checked: Bool)
}

pub type Model {
  Model(
    items_storage: varasto.TypedStorage(List(Item)),
    items: List(Item),
    scanning: Bool,
    editing: Option(String),
    confirm_delete_list: Bool,
    draft_name: String,
    draft_amount: String,
    room_id: String,
    connected: Bool,
    show_share_modal: Bool,
    show_switch_modal: Bool,
    switch_room_input: String,
    copied_toast: Bool,
  )
}

pub type Message {
  Noop

  // Items & Editing
  UserAddedItem(List(#(String, String)))
  UserDeletedItem(String)
  UserToggledItem(String)
  UserAskedToDeleteList
  UserCancelledDeleteList
  UserConfirmedDeleteList
  UserClickedItem(name: String, amount: Int)
  UserChangedDraftName(String)
  UserChangedDraftAmount(String)
  UserConfirmedEdit

  // OCR
  UserSelectedImage(dynamic.Dynamic)
  UserScannedText(String)

  // Real-time synchronization
  RemoteItemsReceived(dynamic.Dynamic)
  ConnectionStatusChanged(Bool)

  // Sharing & Room switching
  UserOpenedShareModal
  UserClosedShareModal
  UserClickedNativeShare
  UserClickedCopyLink
  UserOpenedSwitchModal
  UserClosedSwitchModal
  UserChangedSwitchInput(String)
  UserConfirmedSwitchRoom
  UserGenerateRandomRoom
}

// =============================================================================
// FFI External Bindings
// =============================================================================

@external(javascript, "./frigo_ffi.mjs", "get_file_from_input")
fn get_file_from_input(event: dynamic.Dynamic) -> dynamic.Dynamic

@external(javascript, "./frigo_ffi.mjs", "is_null_file")
fn is_null_file(file: dynamic.Dynamic) -> Bool

@external(javascript, "./frigo_ffi.mjs", "scan_image")
fn do_scan_image(file: dynamic.Dynamic, dispatch: fn(String) -> Nil) -> Nil

@external(javascript, "./frigo_ffi.mjs", "get_active_room_id")
fn get_active_room_id() -> String

@external(javascript, "./frigo_ffi.mjs", "set_active_room_id")
fn set_active_room_id(room_id: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "sanitize_room_id")
fn sanitize_room_id(room_id: String) -> String

@external(javascript, "./frigo_ffi.mjs", "random_room_id")
fn random_room_id() -> String

@external(javascript, "./frigo_ffi.mjs", "start_sync")
fn do_start_sync(
  room_id: String,
  on_sync: fn(dynamic.Dynamic) -> Nil,
  on_status: fn(Bool) -> Nil,
) -> Nil

@external(javascript, "./frigo_ffi.mjs", "broadcast_items_json")
fn broadcast_items_json(json_string: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "share_room_link")
fn share_room_link(room_id: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "copy_to_clipboard")
fn copy_to_clipboard(text: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "get_share_link")
fn get_share_link(room_id: String) -> String

@external(javascript, "./frigo_ffi.mjs", "render_qr_code")
fn render_qr_code(element_id: String, text: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "enable_swipe_to_delete")
fn enable_swipe_to_delete(on_swipe: fn(String) -> Nil) -> Nil

// =============================================================================
// Helper Functions
// =============================================================================

/// Unchecked first, then alphabetical.
pub fn sort_items(items: List(Item)) -> List(Item) {
  list.sort(items, by: fn(a, b) {
    case a.checked, b.checked {
      False, True -> order.Lt
      True, False -> order.Gt
      _, _ -> string.compare(a.name, b.name)
    }
  })
}

/// Adds `amount` to an existing item (unchecking it) or prepends a new one.
pub fn merge_item(items: List(Item), name: String, amount: Int) -> List(Item) {
  case list.any(items, fn(item) { item.name == name }) {
    True ->
      list.map(items, fn(item) {
        case item.name == name {
          True -> Item(..item, amount: item.amount + amount, checked: False)
          False -> item
        }
      })
    False -> [Item(name, amount, False), ..items]
  }
}

pub fn parse_scanned_line(line: String) -> #(String, Int) {
  let words =
    line
    |> string.split(" ")
    |> list.filter(fn(w) { w != "" })

  let amount =
    words
    |> list.find_map(int.parse)
    |> result.unwrap(1)

  let name_words = list.filter(words, fn(w) { result.is_error(int.parse(w)) })

  case name_words {
    [] -> #("", amount)
    _ -> #(string.capitalise(string.join(name_words, " ")), amount)
  }
}

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

      case name {
        "" -> #(model, effect.none())
        _ -> save(model, merge_item(model.items, name, count))
      }
    }

    UserToggledItem(name) ->
      save(
        model,
        list.map(model.items, fn(item) {
          case item.name == name {
            True -> Item(..item, checked: !item.checked)
            False -> item
          }
        }),
      )

    UserDeletedItem(name) ->
      save(model, list.filter(model.items, fn(item) { item.name != name }))

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
    UserClickedItem(name, amount) -> #(
      Model(
        ..model,
        editing: Some(name),
        draft_name: name,
        draft_amount: int.to_string(amount),
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

    UserConfirmedEdit ->
      case model.editing {
        None -> #(model, effect.none())
        Some(original_name) -> {
          let new_name = string.capitalise(string.trim(model.draft_name))
          let original =
            list.find(model.items, fn(item) { item.name == original_name })

          case new_name, int.parse(model.draft_amount), original {
            "", _, _ | _, Error(_), _ | _, _, Error(_) -> #(
              Model(..model, editing: None),
              effect.none(),
            )
            _, Ok(new_amount), Ok(original_item) -> {
              let others =
                list.filter(model.items, fn(item) { item.name != original_name })

              let updated = case
                list.find(others, fn(item) { item.name == new_name })
              {
                Ok(existing) -> [
                  Item(new_name, existing.amount + new_amount, False),
                  ..list.filter(others, fn(item) { item.name != new_name })
                ]
                Error(_) -> [
                  Item(..original_item, name: new_name, amount: new_amount),
                  ..others
                ]
              }

              let #(m, eff) = save(model, updated)
              #(Model(..m, editing: None), eff)
            }
          }
        }
      }

    // --- OCR -----------------------------------------------------------------
    UserSelectedImage(event) -> {
      let file = get_file_from_input(event)
      case is_null_file(file) {
        True -> #(model, effect.none())
        False -> #(
          Model(..model, scanning: True),
          effect.from(fn(dispatch) {
            do_scan_image(file, fn(text) { dispatch(UserScannedText(text)) })
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
          merge_item(acc, pair.0, pair.1)
        })

      let #(m, eff) = save(model, updated)
      #(Model(..m, scanning: False), eff)
    }

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
      Model(..model, connected: is_connected),
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
      effect.from(fn(_) { share_room_link(model.room_id) }),
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
            connected: False,
          ),
          effect.batch([
            effect.from(fn(_) { set_active_room_id(room) }),
            start_sync_effect(room),
          ]),
        )
      }
  }
}

// =============================================================================
// View
// =============================================================================

fn modal(
  on_close: Message,
  title: String,
  children: List(Element(Message)),
) -> Element(Message) {
  html.div([attribute.class("modal-backdrop"), event.on_click(on_close)], [
    html.div(
      [
        attribute.class("modal"),
        // Swallow clicks so they don't bubble up to the backdrop.
        event.stop_propagation(event.on_click(Noop)),
      ],
      [
        html.h3([attribute.class("modal-title")], [element.text(title)]),
        ..children
      ],
    ),
  ])
}

fn text_button(
  class: String,
  on_click: Message,
  label: String,
) -> Element(Message) {
  html.button([attribute.class(class), event.on_click(on_click)], [
    element.text(label),
  ])
}

fn view_item(model: Model, item: Item) -> Element(Message) {
  let checkbox =
    html.input([
      attribute.type_("checkbox"),
      attribute.checked(item.checked),
      event.on_click(UserToggledItem(item.name)),
    ])

  case model.editing {
    Some(name) if name == item.name ->
      html.li([attribute.class("grocery-item editing")], [
        checkbox,
        html.input([
          attribute.class("edit-name"),
          attribute.value(model.draft_name),
          event.on_input(UserChangedDraftName),
        ]),
        html.input([
          attribute.class("edit-amount"),
          attribute.type_("number"),
          attribute.min("1"),
          attribute.value(model.draft_amount),
          event.on_input(UserChangedDraftAmount),
        ]),
        html.button(
          [
            attribute.class("confirm-btn"),
            event.on_click(UserConfirmedEdit),
            attribute.attribute("aria-label", "Guardar cambios"),
          ],
          [element.text("✓")],
        ),
      ])

    _ -> {
      let edit = event.on_click(UserClickedItem(item.name, item.amount))
      html.li(
        [
          attribute.class("grocery-item"),
          attribute.attribute("data-swipe-item", item.name),
        ],
        [
          checkbox,
          html.span(
            [
              attribute.classes([
                #("item-name", True),
                #("crossed", item.checked),
              ]),
              edit,
            ],
            [element.text(item.name)],
          ),
          html.span(
            [
              attribute.classes([
                #("item-amount", True),
                #("crossed", item.checked),
              ]),
              edit,
            ],
            [element.text(int.to_string(item.amount))],
          ),
          html.button(
            [
              attribute.class("delete-btn"),
              event.on_click(UserDeletedItem(item.name)),
              attribute.attribute("aria-label", "Borrar item"),
            ],
            [element.text("×")],
          ),
        ],
      )
    }
  }
}

fn view_share_modal(model: Model) -> Element(Message) {
  case model.show_share_modal {
    False -> element.none()
    True ->
      modal(UserClosedShareModal, "Compartir lista", [
        html.p([attribute.class("modal-desc")], [
          element.text(
            "Cualquiera con este enlace o código podrá ver y editar la lista en tiempo real:",
          ),
        ]),
        html.div([attribute.class("qr-wrapper")], [
          html.div([attribute.id("share-qr-code")], []),
          html.span([attribute.class("qr-hint")], [
            element.text("Escanea con la cámara de otro móvil"),
          ]),
        ]),
        html.div([attribute.class("share-input-row")], [
          html.input([
            attribute.class("input share-url-input"),
            attribute.value(get_share_link(model.room_id)),
            attribute.readonly(True),
          ]),
          text_button(
            "btn copy-btn",
            UserClickedCopyLink,
            case model.copied_toast {
              True -> "¡Copiado!"
              False -> "Copiar"
            },
          ),
        ]),
        html.div([attribute.class("modal-actions")], [
          text_button(
            "btn btn-primary full-width",
            UserClickedNativeShare,
            "📲 Enviar por WhatsApp / Compartir",
          ),
          text_button(
            "btn btn-secondary full-width",
            UserClosedShareModal,
            "Cerrar",
          ),
        ]),
      ])
  }
}

fn view_switch_modal(model: Model) -> Element(Message) {
  case model.show_switch_modal {
    False -> element.none()
    True ->
      modal(UserClosedSwitchModal, "Cambiar de lista", [
        html.p([attribute.class("modal-desc")], [
          element.text(
            "Introduce el nombre o código de la lista a la que quieres unirte:",
          ),
        ]),
        html.div([attribute.class("share-input-row")], [
          html.input([
            attribute.class("input"),
            attribute.placeholder("Ej: casa, finde, compra-familia"),
            attribute.value(model.switch_room_input),
            event.on_input(UserChangedSwitchInput),
          ]),
        ]),
        html.div([attribute.class("modal-actions")], [
          text_button(
            "btn btn-primary full-width",
            UserConfirmedSwitchRoom,
            "Unirme a esta lista",
          ),
          text_button(
            "btn btn-secondary full-width",
            UserGenerateRandomRoom,
            "🎲 Generar código aleatorio",
          ),
          text_button(
            "btn btn-secondary full-width",
            UserClosedSwitchModal,
            "Cancelar",
          ),
        ]),
      ])
  }
}

fn view_delete_modal(model: Model) -> Element(Message) {
  case model.confirm_delete_list {
    False -> element.none()
    True ->
      modal(UserCancelledDeleteList, "¿Vaciar toda la lista?", [
        html.div([attribute.class("modal-actions")], [
          text_button("btn btn-secondary", UserCancelledDeleteList, "Cancelar"),
          text_button("btn btn-danger", UserConfirmedDeleteList, "Vaciar"),
        ]),
      ])
  }
}

fn view(model: Model) -> Element(Message) {
  html.div([attribute.class("frigo-container")], [
    // Top bar
    html.header([attribute.class("app-header")], [
      html.button(
        [
          attribute.class("room-badge"),
          event.on_click(UserOpenedSwitchModal),
          attribute.title("Cambiar de lista"),
        ],
        [
          html.span(
            [
              attribute.classes([
                #("status-dot", True),
                #("online", model.connected),
                #("offline", !model.connected),
              ]),
            ],
            [],
          ),
          html.span([attribute.class("room-name")], [
            element.text(model.room_id),
          ]),
          html.span([attribute.class("room-edit-icon")], [element.text("▾")]),
        ],
      ),
      html.button(
        [
          attribute.class("share-btn"),
          event.on_click(UserOpenedShareModal),
          attribute.title("Compartir esta lista"),
        ],
        [element.text("👥 Compartir")],
      ),
    ]),
    // Add item form
    html.form([attribute.class("form"), event.on_submit(UserAddedItem)], [
      html.input([
        attribute.name("input_form"),
        attribute.placeholder("Producto (ej: Leche)..."),
        attribute.required(True),
        attribute.class("input"),
      ]),
      html.input([
        attribute.name("input_count"),
        attribute.type_("number"),
        attribute.class("input-number"),
        attribute.min("1"),
        attribute.value("1"),
      ]),
      html.button([attribute.type_("submit"), attribute.class("btn")], [
        element.text("Añadir"),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("btn btn-danger"),
          event.on_click(UserAskedToDeleteList),
          attribute.title("Vaciar toda la lista"),
        ],
        [element.text("Vaciar")],
      ),
    ]),
    // OCR
    html.div([attribute.class("scan-section")], [
      html.label(
        [
          attribute.class("btn btn-scan"),
          attribute.attribute("for", "scan-input"),
        ],
        [
          element.text(case model.scanning {
            True -> "📷 Escaneando imagen..."
            False -> "📷 Escanear lista en papel"
          }),
        ],
      ),
      html.input([
        attribute.type_("file"),
        attribute.id("scan-input"),
        attribute.attribute("accept", "image/*"),
        attribute.attribute("capture", "environment"),
        attribute.attribute("hidden", ""),
        event.on("change", decode.map(decode.dynamic, UserSelectedImage)),
      ]),
    ]),
    html.ul(
      [attribute.class("list")],
      list.map(model.items, fn(item) { view_item(model, item) }),
    ),
    view_share_modal(model),
    view_switch_modal(model),
    view_delete_modal(model),
  ])
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
      room_id: room,
      connected: False,
      show_share_modal: False,
      show_switch_modal: False,
      switch_room_input: "",
      copied_toast: False,
    ),
    effect.batch([
      effect.from(fn(dispatch) {
        enable_swipe_to_delete(fn(name) { dispatch(UserDeletedItem(name)) })
      }),
      start_sync_effect(room),
    ]),
  )
}

// =============================================================================
// Decoders & Encoders
// =============================================================================

pub fn reader() {
  decode.list({
    use name <- decode.field("name", decode.string)
    use amount <- decode.field("number", decode.int)
    use checked <- decode.field("checked", decode.bool)
    decode.success(Item(name:, amount:, checked:))
  })
}

pub fn writer(items: List(Item)) {
  use item <- json.array(items)
  json.object([
    #("checked", json.bool(item.checked)),
    #("name", json.string(item.name)),
    #("number", json.int(item.amount)),
  ])
}
