import categories
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{Some}
import items.{type Item}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import model.{
  type Message, type Model, Connected, Connecting, Disconnected, Noop,
  UserAddedItem, UserAskedToDeleteList, UserCancelledDeleteList,
  UserChangedDraftAmount, UserChangedDraftCategory, UserChangedDraftName,
  UserChangedSwitchInput, UserClickedCopyLink, UserClickedItem,
  UserClickedNativeShare, UserClosedShareModal, UserClosedSwitchModal,
  UserConfirmedDeleteList, UserConfirmedEdit, UserConfirmedSwitchRoom,
  UserDeletedItem, UserGenerateRandomRoom, UserOpenedShareModal,
  UserOpenedSwitchModal, UserSelectedImage, UserToggledItem, UserToggledSection,
}

fn modal(
  on_close: Message,
  title: String,
  children: List(Element(Message)),
) -> Element(Message) {
  html.div([attribute.class("modal-backdrop"), event.on_click(on_close)], [
    html.div(
      [
        attribute.class("modal"),
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
        html.div([attribute.class("edit-fields-column")], [
          html.div([attribute.class("edit-name-amount-row")], [
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
          ]),
          html.select(
            [
              attribute.class("edit-category-select"),
              event.on_input(UserChangedDraftCategory),
            ],
            list.map(categories.standard_categories, fn(category) {
              html.option(
                [
                  attribute.value(category),
                  attribute.selected(model.draft_category == category),
                ],
                category,
              )
            }),
          ),
        ]),
      ])

    _ -> {
      let edit =
        event.on_click(UserClickedItem(item.name, item.amount, item.category))
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

fn view_share_modal(model: Model, share_url: String) -> Element(Message) {
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
            attribute.value(share_url),
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

fn view_category_section(
  model: Model,
  category: String,
  items: List(Item),
) -> Element(Message) {
  let is_collapsed = list.contains(model.collapsed_sections, category)
  let total_count = list.length(items)
  let done_count = list.count(items, fn(item) { item.checked })
  let pending_count = total_count - done_count
  let all_done = total_count > 0 && done_count == total_count

  html.section([attribute.class("category-section")], [
    html.div(
      [
        attribute.class("category-header"),
        event.on_click(UserToggledSection(category)),
      ],
      [
        html.div([attribute.class("category-title")], [
          html.span(
            [
              attribute.classes([
                #("category-arrow", True),
                #("collapsed", is_collapsed),
              ]),
            ],
            [
              element.text(case is_collapsed {
                True -> "▶"
                False -> "▼"
              }),
            ],
          ),
          element.text(category),
        ]),
        html.span([attribute.class("category-badge")], [
          element.text(case all_done {
            True -> "✓ Completa"
            False ->
              int.to_string(pending_count)
              <> " pendiente"
              <> case pending_count == 1 {
                True -> ""
                False -> "s"
              }
          }),
        ]),
      ],
    ),
    case is_collapsed {
      True -> element.none()
      False ->
        html.ul(
          [attribute.class("list category-list")],
          list.map(items, fn(item) { view_item(model, item) }),
        )
    },
  ])
}

pub fn view(model: Model, share_url: String) -> Element(Message) {
  let active_categories =
    list.filter(categories.standard_categories, fn(category) {
      list.any(model.items, fn(item) { item.category == category })
    })
  let uncategorized_items =
    list.filter(model.items, fn(item) {
      !list.contains(categories.standard_categories, item.category)
    })
  let sections =
    list.map(active_categories, fn(category) {
      view_category_section(
        model,
        category,
        list.filter(model.items, fn(item) { item.category == category }),
      )
    })
  let all_sections = case uncategorized_items {
    [] -> sections
    _ ->
      list.append(sections, [
        view_category_section(model, "📦 Otros", uncategorized_items),
      ])
  }

  html.div([attribute.class("frigo-container")], [
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
                #("online", model.connection_status == Connected),
                #("offline", model.connection_status == Disconnected),
              ]),
            ],
            [],
          ),
          html.span([attribute.class("room-name")], [
            element.text(model.room_id),
          ]),
          html.span([attribute.class("connection-label")], [
            element.text(case model.connection_status {
              Connecting -> "Conectando..."
              Connected -> "Online"
              Disconnected -> "Sin conexión"
            }),
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
      html.select(
        [
          attribute.name("input_category"),
          attribute.class("category-select"),
          attribute.title("Categoría del producto"),
        ],
        [
          html.option([attribute.value("")], "Automática"),
          ..list.map(categories.standard_categories, fn(category) {
            html.option([attribute.value(category)], category)
          })
        ],
      ),
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
    case model.items {
      [] ->
        html.div([attribute.class("empty-list-hint")], [
          element.text(
            "Tu lista está vacía. Añade productos o escanea una foto con 📷",
          ),
        ])
      _ -> html.div([attribute.class("categories-container")], all_sections)
    },
    view_share_modal(model, share_url),
    view_switch_modal(model),
    view_delete_modal(model),
  ])
}
