import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
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
  CheckedItem(name: String, amount: Int)
  UncheckedItem(name: String, amount: Int)
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
  UserDismissedToast
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

@external(javascript, "./frigo_ffi.mjs", "start_sync")
fn do_start_sync(
  room_id: String,
  on_sync: fn(dynamic.Dynamic) -> Nil,
  on_status: fn(Bool) -> Nil,
) -> Nil

@external(javascript, "./frigo_ffi.mjs", "broadcast_items_json")
fn broadcast_items_json(json_string: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "share_room_link")
fn share_room_link(room_id: String) -> Bool

@external(javascript, "./frigo_ffi.mjs", "copy_to_clipboard")
fn copy_to_clipboard(text: String) -> Bool

@external(javascript, "./frigo_ffi.mjs", "get_share_link")
fn get_share_link(room_id: String) -> String

@external(javascript, "./frigo_ffi.mjs", "render_qr_code")
fn render_qr_code(element_id: String, text: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "enable_swipe_to_delete")
fn enable_swipe_to_delete(on_swipe: fn(String) -> Nil) -> Nil

// =============================================================================
// Helper Functions
// =============================================================================

pub fn is_checked(item: Item) -> Bool {
  case item {
    CheckedItem(..) -> True
    UncheckedItem(..) -> False
  }
}

pub fn sort_items(items: List(Item)) -> List(Item) {
  let unchecked =
    items
    |> list.filter(fn(item) { !is_checked(item) })
    |> list.sort(by: fn(a, b) { string.compare(a.name, b.name) })

  let checked =
    items
    |> list.filter(is_checked)
    |> list.sort(by: fn(a, b) { string.compare(a.name, b.name) })

  list.append(unchecked, checked)
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

fn items_to_json_string(items: List(Item)) -> String {
  writer(items)
  |> json.to_string
}

fn load_room_items(
  storage: varasto.TypedStorage(List(Item)),
  room_id: String,
) -> List(Item) {
  case varasto.get(storage, "items_" <> room_id) {
    Ok(cached) -> cached
    Error(_) ->
      case varasto.get(storage, "items") {
        Ok(legacy) -> legacy
        Error(_) -> []
      }
  }
}

fn persist_and_broadcast_effect(
  storage: varasto.TypedStorage(List(Item)),
  room_id: String,
  items: List(Item),
) -> effect.Effect(Message) {
  effect.from(fn(_) {
    let _ = varasto.set(storage, "items_" <> room_id, items)
    broadcast_items_json(items_to_json_string(items))
    Nil
  })
}

// =============================================================================
// Update Loop
// =============================================================================

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case message {
    // -------------------------------------------------------------------------
    // Adding Items
    // -------------------------------------------------------------------------
    UserAddedItem(form_item) -> {
      let assert Ok(name) = list.key_find(form_item, "input_form")
      let assert Ok(count_str) = list.key_find(form_item, "input_count")
      let assert Ok(count) = int.parse(count_str)
      let formatted_name = string.capitalise(string.trim(name))

      case formatted_name {
        "" -> #(model, effect.none())
        _ -> {
          let item_exists =
            list.any(model.items, fn(item) { item.name == formatted_name })

          let updated_list = case item_exists {
            True ->
              list.map(model.items, fn(item) {
                case item.name == formatted_name {
                  True -> UncheckedItem(item.name, item.amount + count)
                  False -> item
                }
              })
            False -> [UncheckedItem(formatted_name, count), ..model.items]
          }

          let sorted_list = sort_items(updated_list)

          #(
            Model(..model, items: sorted_list),
            persist_and_broadcast_effect(
              model.items_storage,
              model.room_id,
              sorted_list,
            ),
          )
        }
      }
    }

    // -------------------------------------------------------------------------
    // Toggling Checkbox
    // -------------------------------------------------------------------------
    UserToggledItem(name) -> {
      let toggled =
        list.map(model.items, fn(item: Item) {
          case item.name == name {
            True -> {
              case item {
                CheckedItem(n, a) -> UncheckedItem(n, a)
                UncheckedItem(n, a) -> CheckedItem(n, a)
              }
            }
            False -> item
          }
        })

      let sorted = sort_items(toggled)

      #(
        Model(..model, items: sorted),
        persist_and_broadcast_effect(model.items_storage, model.room_id, sorted),
      )
    }

    // -------------------------------------------------------------------------
    // Deleting Single Item
    // -------------------------------------------------------------------------
    UserDeletedItem(name) -> {
      let filtered =
        list.filter(model.items, fn(item: Item) { item.name != name })
      #(
        Model(..model, items: filtered),
        persist_and_broadcast_effect(
          model.items_storage,
          model.room_id,
          filtered,
        ),
      )
    }

    // -------------------------------------------------------------------------
    // Clear All Items Modal
    // -------------------------------------------------------------------------
    UserAskedToDeleteList -> #(
      Model(..model, confirm_delete_list: True),
      effect.none(),
    )

    UserCancelledDeleteList -> #(
      Model(..model, confirm_delete_list: False),
      effect.none(),
    )

    UserConfirmedDeleteList -> {
      let empty_list = []
      #(
        Model(..model, items: empty_list, confirm_delete_list: False),
        persist_and_broadcast_effect(
          model.items_storage,
          model.room_id,
          empty_list,
        ),
      )
    }

    // -------------------------------------------------------------------------
    // Inline Editing
    // -------------------------------------------------------------------------
    UserClickedItem(name, amount) -> {
      #(
        Model(
          ..model,
          editing: Some(name),
          draft_name: name,
          draft_amount: int.to_string(amount),
        ),
        effect.none(),
      )
    }

    UserChangedDraftName(value) -> {
      #(Model(..model, draft_name: value), effect.none())
    }

    UserChangedDraftAmount(value) -> {
      #(Model(..model, draft_amount: value), effect.none())
    }

    UserConfirmedEdit -> {
      case model.editing {
        None -> #(model, effect.none())
        Some(original_name) -> {
          let new_name = string.capitalise(string.trim(model.draft_name))
          case new_name {
            "" -> #(Model(..model, editing: None), effect.none())
            _ ->
              case int.parse(model.draft_amount) {
                Error(_) -> #(Model(..model, editing: None), effect.none())
                Ok(new_amount) -> {
                  let assert Ok(original_item) =
                    list.find(model.items, fn(item) {
                      item.name == original_name
                    })

                  let without_original =
                    list.filter(model.items, fn(item) {
                      item.name != original_name
                    })

                  let clash =
                    list.find(without_original, fn(item) {
                      item.name == new_name
                    })

                  let updated_list = case clash {
                    Ok(existing) -> [
                      UncheckedItem(new_name, existing.amount + new_amount),
                      ..list.filter(without_original, fn(item) {
                        item.name != new_name
                      })
                    ]
                    Error(_) -> {
                      let renamed = case original_item {
                        CheckedItem(..) -> CheckedItem(new_name, new_amount)
                        UncheckedItem(..) -> UncheckedItem(new_name, new_amount)
                      }
                      [renamed, ..without_original]
                    }
                  }

                  let sorted = sort_items(updated_list)

                  #(
                    Model(..model, items: sorted, editing: None),
                    persist_and_broadcast_effect(
                      model.items_storage,
                      model.room_id,
                      sorted,
                    ),
                  )
                }
              }
          }
        }
      }
    }

    // -------------------------------------------------------------------------
    // OCR Scanning
    // -------------------------------------------------------------------------
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
      let parsed_lines =
        text
        |> string.split("\n")
        |> list.map(string.trim)
        |> list.filter(fn(l) { l != "" })
        |> list.map(parse_scanned_line)
        |> list.filter(fn(pair) { pair.0 != "" })

      let updated_list =
        list.fold(parsed_lines, model.items, fn(acc, pair) {
          let #(name, amount) = pair
          let item_exists = list.any(acc, fn(item) { item.name == name })
          case item_exists {
            True ->
              list.map(acc, fn(item) {
                case item.name == name {
                  True -> UncheckedItem(item.name, item.amount + amount)
                  False -> item
                }
              })
            False -> [UncheckedItem(name, amount), ..acc]
          }
        })

      let sorted = sort_items(updated_list)

      #(
        Model(..model, items: sorted, scanning: False),
        persist_and_broadcast_effect(model.items_storage, model.room_id, sorted),
      )
    }

    // -------------------------------------------------------------------------
    // Real-time synchronization
    // -------------------------------------------------------------------------
    RemoteItemsReceived(raw_dynamic) -> {
      case decode.run(raw_dynamic, reader()) {
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
    }

    ConnectionStatusChanged(is_connected) -> #(
      Model(..model, connected: is_connected),
      effect.none(),
    )

    // -------------------------------------------------------------------------
    // Sharing Modal
    // -------------------------------------------------------------------------
    UserOpenedShareModal -> {
      let share_link = get_share_link(model.room_id)
      #(
        Model(..model, show_share_modal: True),
        effect.from(fn(_) {
          render_qr_code("share-qr-code", share_link)
          Nil
        }),
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

    UserClickedCopyLink -> {
      let link = get_share_link(model.room_id)
      #(
        Model(..model, copied_toast: True),
        effect.from(fn(_) {
          let _ = copy_to_clipboard(link)
          Nil
        }),
      )
    }

    UserDismissedToast -> #(Model(..model, copied_toast: False), effect.none())

    // -------------------------------------------------------------------------
    // Room Switching
    // -------------------------------------------------------------------------
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

    UserGenerateRandomRoom -> {
      let clean_room =
        "frigo-"
        <> string.slice(
          string.lowercase(int.to_base16(int.random(65_535))),
          0,
          4,
        )
      #(Model(..model, switch_room_input: clean_room), effect.none())
    }

    UserConfirmedSwitchRoom -> {
      let clean_room =
        model.switch_room_input
        |> string.trim
        |> string.lowercase

      case clean_room {
        "" -> #(model, effect.none())
        _ -> {
          let new_items = load_room_items(model.items_storage, clean_room)
          #(
            Model(
              ..model,
              room_id: clean_room,
              items: new_items,
              show_switch_modal: False,
              connected: False,
            ),
            effect.from(fn(dispatch) {
              set_active_room_id(clean_room)
              do_start_sync(
                clean_room,
                fn(raw) { dispatch(RemoteItemsReceived(raw)) },
                fn(status) { dispatch(ConnectionStatusChanged(status)) },
              )
            }),
          )
        }
      }
    }
  }
}

// =============================================================================
// View
// =============================================================================

fn view(model: Model) -> Element(Message) {
  let share_url = get_share_link(model.room_id)

  let rendered_items =
    list.map(model.items, fn(item: Item) {
      let done = is_checked(item)
      let checkbox =
        html.input([
          attribute.type_("checkbox"),
          attribute.checked(done),
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

        _ ->
          html.li(
            [
              attribute.class("grocery-item"),
              attribute.attribute("data-swipe-item", item.name),
            ],
            [
              checkbox,
              html.span(
                [
                  attribute.classes([#("crossed", done)]),
                  attribute.class("item-name"),
                  event.on_click(UserClickedItem(item.name, item.amount)),
                ],
                [element.text(item.name)],
              ),
              html.span(
                [
                  attribute.classes([#("crossed", done)]),
                  attribute.class("item-amount"),
                  event.on_click(UserClickedItem(item.name, item.amount)),
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
    })

  html.div([attribute.class("frigo-container")], [
    // Top Bar: Room Chip & Share Button
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
        [
          html.span([attribute.class("share-icon")], [element.text("👥")]),
          element.text(" Compartir"),
        ],
      ),
    ]),
    // Add Item Form
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
    // Scan with OCR
    html.div([attribute.class("scan-section")], [
      html.label(
        [
          attribute.class("btn btn-scan"),
          attribute.attribute("for", "scan-input"),
        ],
        [
          html.span([], [element.text("📷 ")]),
          element.text(case model.scanning {
            True -> "Escaneando imagen..."
            False -> "Escanear lista en papel"
          }),
        ],
      ),
      html.input([
        attribute.type_("file"),
        attribute.id("scan-input"),
        attribute.attribute("accept", "image/*"),
        attribute.attribute("capture", "environment"),
        attribute.attribute("style", "display:none"),
        event.on("change", decode.map(decode.dynamic, UserSelectedImage)),
      ]),
    ]),
    // Items List
    html.ul([attribute.class("list")], rendered_items),
    // Share Modal
    case model.show_share_modal {
      True ->
        html.div(
          [
            attribute.class("modal-backdrop"),
            event.on_click(UserClosedShareModal),
          ],
          [
            html.div(
              [
                attribute.class("modal share-modal"),
                event.stop_propagation(event.on_click(UserClosedShareModal)),
              ],
              [
                html.h3([attribute.class("modal-title")], [
                  element.text("Compartir lista"),
                ]),
                html.p([attribute.class("modal-desc")], [
                  element.text(
                    "Cualquiera con este enlace o código podrá ver y editar la lista en tiempo real:",
                  ),
                ]),
                // QR Code Display
                html.div([attribute.class("qr-wrapper")], [
                  html.div([attribute.id("share-qr-code")], []),
                  html.span([attribute.class("qr-hint")], [
                    element.text("Escanea con la cámara de otro móvil"),
                  ]),
                ]),
                // Copy Link Row
                html.div([attribute.class("share-input-row")], [
                  html.input([
                    attribute.class("input share-url-input"),
                    attribute.value(share_url),
                    attribute.readonly(True),
                  ]),
                  html.button(
                    [
                      attribute.class("btn copy-btn"),
                      event.on_click(UserClickedCopyLink),
                    ],
                    [
                      element.text(case model.copied_toast {
                        True -> "¡Copiado!"
                        False -> "Copiar"
                      }),
                    ],
                  ),
                ]),
                // Action Buttons
                html.div([attribute.class("modal-actions")], [
                  html.button(
                    [
                      attribute.class("btn btn-primary full-width"),
                      event.on_click(UserClickedNativeShare),
                    ],
                    [element.text("📲 Enviar por WhatsApp / Compartir")],
                  ),
                  html.button(
                    [
                      attribute.class("btn btn-secondary full-width"),
                      event.on_click(UserClosedShareModal),
                    ],
                    [element.text("Cerrar")],
                  ),
                ]),
              ],
            ),
          ],
        )
      False -> html.text("")
    },
    // Switch Room Modal
    case model.show_switch_modal {
      True ->
        html.div(
          [
            attribute.class("modal-backdrop"),
            event.on_click(UserClosedSwitchModal),
          ],
          [
            html.div(
              [
                attribute.class("modal"),
                event.stop_propagation(event.on_click(UserClosedSwitchModal)),
              ],
              [
                html.h3([attribute.class("modal-title")], [
                  element.text("Cambiar de lista"),
                ]),
                html.p([attribute.class("modal-desc")], [
                  element.text(
                    "Introduce el nombre o código de la lista a la que quieres unirte:",
                  ),
                ]),
                html.div([attribute.class("switch-input-row")], [
                  html.input([
                    attribute.class("input"),
                    attribute.placeholder("Ej: casa, finde, compra-familia"),
                    attribute.value(model.switch_room_input),
                    event.on_input(UserChangedSwitchInput),
                  ]),
                ]),
                html.div([attribute.class("modal-actions-column")], [
                  html.button(
                    [
                      attribute.class("btn btn-primary full-width"),
                      event.on_click(UserConfirmedSwitchRoom),
                    ],
                    [element.text("Unirme a esta lista")],
                  ),
                  html.button(
                    [
                      attribute.class("btn btn-secondary full-width"),
                      event.on_click(UserGenerateRandomRoom),
                    ],
                    [element.text("🎲 Generar código aleatorio")],
                  ),
                  html.button(
                    [
                      attribute.class("btn btn-secondary full-width"),
                      event.on_click(UserClosedSwitchModal),
                    ],
                    [element.text("Cancelar")],
                  ),
                ]),
              ],
            ),
          ],
        )
      False -> html.text("")
    },
    // Confirm Delete Entire List Modal
    case model.confirm_delete_list {
      True ->
        html.div(
          [
            attribute.class("modal-backdrop"),
            event.on_click(UserCancelledDeleteList),
          ],
          [
            html.div(
              [
                attribute.class("modal"),
                event.stop_propagation(event.on_click(UserCancelledDeleteList)),
              ],
              [
                html.p([attribute.class("modal-title")], [
                  element.text("¿Vaciar toda la lista?"),
                ]),
                html.div([attribute.class("modal-actions")], [
                  html.button(
                    [
                      attribute.class("btn btn-secondary"),
                      event.on_click(UserCancelledDeleteList),
                    ],
                    [element.text("Cancelar")],
                  ),
                  html.button(
                    [
                      attribute.class("btn btn-danger"),
                      event.on_click(UserConfirmedDeleteList),
                    ],
                    [element.text("Vaciar")],
                  ),
                ]),
              ],
            ),
          ],
        )
      False -> html.text("")
    },
  ])
}

// =============================================================================
// Initialization
// =============================================================================

fn init(_initial: Int) -> #(Model, effect.Effect(Message)) {
  let assert Ok(local) = varasto.local()
  let s = varasto.new(local, reader(), writer)
  let initial_room = get_active_room_id()
  let initial_items = load_room_items(s, initial_room)

  let initial_model =
    Model(
      items_storage: s,
      items: initial_items,
      scanning: False,
      editing: None,
      confirm_delete_list: False,
      draft_name: "",
      draft_amount: "",
      room_id: initial_room,
      connected: False,
      show_share_modal: False,
      show_switch_modal: False,
      switch_room_input: "",
      copied_toast: False,
    )

  let sync_effect =
    effect.from(fn(dispatch) {
      enable_swipe_to_delete(fn(name) { dispatch(UserDeletedItem(name)) })
      do_start_sync(
        initial_room,
        fn(raw_items) { dispatch(RemoteItemsReceived(raw_items)) },
        fn(is_connected) { dispatch(ConnectionStatusChanged(is_connected)) },
      )
    })

  #(initial_model, sync_effect)
}

// =============================================================================
// Decoders & Encoders
// =============================================================================

pub fn reader() {
  let tuple_decoder = {
    use name <- decode.field("name", decode.string)
    use amount <- decode.field("number", decode.int)
    use checked <- decode.field("checked", decode.bool)
    decode.success(case checked {
      True -> CheckedItem(name:, amount:)
      False -> UncheckedItem(name:, amount:)
    })
  }
  decode.list(tuple_decoder)
}

pub fn writer(lista_item: List(Item)) {
  use item <- json.array(lista_item)
  json.object([
    case item {
      CheckedItem(..) -> #("checked", json.bool(True))
      UncheckedItem(..) -> #("checked", json.bool(False))
    },
    #("name", json.string(item.name)),
    #("number", json.int(item.amount)),
  ])
}
