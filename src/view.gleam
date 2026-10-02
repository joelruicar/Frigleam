import categories
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import items.{type Item}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import model.{
  type Message, type Model, Noop,
  UserAddedItem, UserAskedToDeleteList, UserCancelledDeleteList,
  UserChangedDraftAmount, UserChangedDraftCategory, UserChangedDraftName,
  UserChangedSwitchInput, UserClickedCopyLink, UserClickedItem,
  UserClickedNativeShare, UserClosedShareModal, UserClosedSwitchModal,
  UserConfirmedDeleteList, UserConfirmedEdit, UserConfirmedSwitchRoom,
  UserDeletedItem, UserGenerateRandomRoom, UserOpenedShareModal,
  UserOpenedSwitchModal, UserSelectedImage, UserSelectedTab,
  UserToggledCartMenu, UserToggledItem,
}

fn view_item(model: Model, item: Item) -> Element(Message) {
  let checkbox =
    html.button(
      [
        attribute.type_("button"),
        attribute.classes([
          #("custom-checkbox", True),
          #("checked", item.checked),
        ]),
        event.on_click(UserToggledItem(item.id)),
        attribute.attribute("aria-label", case item.checked {
          True -> "Desmarcar " <> item.name
          False -> "Marcar " <> item.name
        }),
      ],
      [],
    )

  case model.editing {
    Some(id) if id == item.id ->
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
        event.on_click(UserClickedItem(
          item.id,
          item.name,
          item.amount,
          item.category,
        ))
      html.li(
        [
          attribute.classes([
            #("grocery-item", True),
            #("item-checked", item.checked),
          ]),
          attribute.attribute("data-swipe-item", item.id),
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
              event.on_click(UserDeletedItem(item.id)),
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
      html.div(
        [
          attribute.class("modal-backdrop"),
          event.on_click(UserClosedShareModal),
        ],
        [
          html.div(
            [
              attribute.class("share-modal-sheet"),
              event.stop_propagation(event.on_click(Noop)),
            ],
            [
              html.div([attribute.class("qr-centered-box")], [
                html.div([attribute.id("share-qr-code")], []),
              ]),
              html.div([attribute.class("share-url-row")], [
                html.input([
                  attribute.class("share-url-pill"),
                  attribute.value(share_url),
                  attribute.readonly(True),
                ]),
                html.button(
                  [
                    attribute.type_("button"),
                    attribute.class("btn-copy-pill"),
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
              html.button(
                [
                  attribute.type_("button"),
                  attribute.class("btn-share-por-pill"),
                  event.on_click(UserClickedNativeShare),
                ],
                [element.text("Compartir por...")],
              ),
              html.button(
                [
                  attribute.type_("button"),
                  attribute.class("btn-cerrar-outline-pill"),
                  event.on_click(UserClosedShareModal),
                ],
                [element.text("Cerrar")],
              ),
            ],
          ),
        ],
      )
  }
}

fn view_switch_modal(model: Model) -> Element(Message) {
  case model.show_switch_modal {
    False -> element.none()
    True ->
      html.div(
        [
          attribute.class("modal-backdrop"),
          event.on_click(UserClosedSwitchModal),
        ],
        [
          html.div(
            [
              attribute.class("switch-modal-sheet"),
              event.stop_propagation(event.on_click(Noop)),
            ],
            [
              html.h3([attribute.class("sheet-title")], [element.text("Mis listas")]),
              html.p([attribute.class("sheet-desc")], [
                element.text("Introduce el nombre de la lista:"),
              ]),
              html.div([attribute.class("sheet-input-row")], [
                html.input([
                  attribute.class("sheet-input-pill"),
                  attribute.placeholder("Ej: casa, finde..."),
                  attribute.value(model.switch_room_input),
                  event.on_input(UserChangedSwitchInput),
                ]),
              ]),
              html.div([attribute.class("sheet-actions")], [
                html.button(
                  [
                    attribute.type_("button"),
                    attribute.class("btn-share-por-pill"),
                    event.on_click(UserConfirmedSwitchRoom),
                  ],
                  [element.text("Unirme a esta lista")],
                ),
                html.button(
                  [
                    attribute.type_("button"),
                    attribute.class("btn-random-pill"),
                    event.on_click(UserGenerateRandomRoom),
                  ],
                  [element.text("🎲 Generar código aleatorio")],
                ),
                html.button(
                  [
                    attribute.type_("button"),
                    attribute.class("btn-cerrar-outline-pill"),
                    event.on_click(UserClosedSwitchModal),
                  ],
                  [element.text("Cerrar")],
                ),
              ]),
            ],
          ),
        ],
      )
  }
}

fn view_delete_modal(model: Model) -> Element(Message) {
  case model.confirm_delete_list {
    False -> element.none()
    True ->
      html.div(
        [
          attribute.class("modal-backdrop"),
          event.on_click(UserCancelledDeleteList),
        ],
        [
          html.div(
            [
              attribute.class("delete-modal-sheet"),
              event.stop_propagation(event.on_click(Noop)),
            ],
            [
              html.h3([attribute.class("sheet-title")], [
                element.text("¿Vaciar toda la lista?"),
              ]),
              html.div([attribute.class("sheet-actions-row")], [
                html.button(
                  [
                    attribute.type_("button"),
                    attribute.class("btn-cerrar-outline-pill"),
                    event.on_click(UserCancelledDeleteList),
                  ],
                  [element.text("Cancelar")],
                ),
                html.button(
                  [
                    attribute.type_("button"),
                    attribute.class("btn-delete-confirm-pill"),
                    event.on_click(UserConfirmedDeleteList),
                  ],
                  [element.text("Vaciar")],
                ),
              ]),
            ],
          ),
        ],
      )
  }
}

pub fn view(model: Model, share_url: String) -> Element(Message) {
  let standard_active =
    list.filter(categories.standard_categories, fn(category) {
      list.any(model.items, fn(item) { item.category == category })
    })
  let uncategorized_items =
    list.filter(model.items, fn(item) {
      !list.contains(categories.standard_categories, item.category)
    })
  let active_categories = case uncategorized_items {
    [] -> standard_active
    _ ->
      case list.contains(standard_active, "📦 Otros") {
        True -> standard_active
        False -> list.append(standard_active, ["📦 Otros"])
      }
  }

  // If there are more than 2 categories (total tabs > 3 with "Todo"),
  // use representative icons instead of text.
  let too_many_tabs = list.length(active_categories) > 2

  // Filter items by selected tab:
  let displayed_items = case model.selected_tab {
    "Todo" -> model.items
    cat -> list.filter(model.items, fn(item) { item.category == cat })
  }

  let total_count = list.length(displayed_items)
  let checked_count = list.count(displayed_items, fn(item) { item.checked })
  let counter_str =
    int.to_string(checked_count) <> "/" <> int.to_string(total_count)

  let todo_tab =
    html.button(
      [
        attribute.type_("button"),
        attribute.classes([
          #("tab-btn", True),
          #("tab-todo", True),
          #("active", model.selected_tab == "Todo"),
        ]),
        event.on_click(UserSelectedTab("Todo")),
        attribute.title("Ver todos los productos"),
      ],
      [element.text("Todo")],
    )

  let category_tabs =
    list.map(active_categories, fn(cat) {
      let is_active = model.selected_tab == cat
      let label = case too_many_tabs {
        True -> categories.category_icon(cat)
        False -> categories.category_short_name(cat)
      }
      html.button(
        [
          attribute.type_("button"),
          attribute.classes([
            #("tab-btn", True),
            #("tab-" <> categories.category_slug(cat), True),
            #("active", is_active),
            #("tab-icon-only", too_many_tabs),
          ]),
          event.on_click(UserSelectedTab(cat)),
          attribute.title(cat),
          attribute.attribute("aria-label", cat),
        ],
        [element.text(label)],
      )
    })

  let all_tabs = [todo_tab, ..category_tabs]

  html.div([attribute.class("frigo-container")], [
    // Banner Frigleam + Cart badge with Dropdown
    html.header([attribute.class("frigleam-header")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("cart-badge-ring"),
          event.on_click(UserToggledCartMenu),
          attribute.title("Menú de opciones"),
          attribute.attribute("aria-label", "Menú de opciones"),
        ],
        [
          html.img([
            attribute.src("/cart.png"),
            attribute.alt("Carrito"),
            attribute.class("cart-badge-img"),
          ]),
        ],
      ),
      case model.show_cart_menu {
        False -> element.none()
        True ->
          html.div([attribute.class("cart-dropdown-menu")], [
            html.button(
              [
                attribute.type_("button"),
                attribute.class("dropdown-item-btn"),
                event.on_click(UserOpenedSwitchModal),
              ],
              [element.text("Mis listas")],
            ),
            html.button(
              [
                attribute.type_("button"),
                attribute.class("dropdown-item-btn"),
                event.on_click(UserOpenedShareModal),
              ],
              [element.text("Compartir")],
            ),
            html.button(
              [
                attribute.type_("button"),
                attribute.class("dropdown-item-btn"),
                event.on_click(UserToggledCartMenu),
              ],
              [element.text("Lenguaje")],
            ),
            html.button(
              [
                attribute.type_("button"),
                attribute.class("dropdown-item-btn"),
                event.on_click(UserToggledCartMenu),
              ],
              [element.text("Modo oscuro")],
            ),
          ])
      },
      html.div([attribute.class("frigleam-banner-pill")], [
        html.h1([attribute.class("frigleam-title")], [element.text("Frigleam")]),
        html.div([attribute.class("frigleam-underline")], []),
      ]),
    ]),

    // Add item form
    html.form([attribute.class("add-item-form"), event.on_submit(UserAddedItem)], [
      html.div([attribute.class("input-actions-row")], [
        html.div([attribute.class("input-pill-wrapper")], [
          html.input([
            attribute.name("input_form"),
            attribute.id("product-input"),
            attribute.placeholder("Leche, ajos..."),
            attribute.required(True),
            attribute.class("input-product"),
            attribute.autocomplete("off"),
          ]),
          html.button(
            [
              attribute.type_("button"),
              attribute.id("voice-input-btn"),
              attribute.class("btn-mic-inside"),
              attribute.title("Dictar por voz"),
              attribute.attribute("aria-label", "Dictar por voz"),
            ],
            [],
          ),
        ]),
        html.label(
          [
            attribute.class("btn-cam-outside"),
            attribute.attribute("for", "scan-input"),
            attribute.title("Escanear lista en papel"),
            attribute.attribute("aria-label", "Escanear lista en papel"),
          ],
          [],
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
      html.button(
        [
          attribute.type_("submit"),
          attribute.class("btn-aceptar-pill"),
        ],
        [element.text("Aceptar")],
      ),
    ]),

    // OCR feedback
    case model.scanning {
      True ->
        html.div([attribute.class("scanning-status-pill")], [
          element.text("📷 Escaneando imagen con OCR..."),
        ])
      False -> element.none()
    },
    case model.ocr_error {
      None -> element.none()
      Some(error) ->
        html.div(
          [attribute.class("ocr-error-pill"), attribute.attribute("role", "alert")],
          [element.text("No se pudo escanear: " <> error)],
        )
    },

    // Category Tabs
    html.nav([attribute.class("tabs-nav-bar")], all_tabs),

    // List surface
    html.div([attribute.class("list-card-surface")], [
      html.div([attribute.class("list-top-meta-row")], [
        html.span([attribute.class("list-counter-badge")], [
          element.text(counter_str),
        ]),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("btn-vaciar-outline"),
            event.on_click(UserAskedToDeleteList),
            attribute.title("Vaciar toda la lista"),
          ],
          [element.text("Vaciar")],
        ),
      ]),

      html.div([attribute.class("list-columns-header")], [
        html.span([attribute.class("col-product-name")], [element.text("Producto")]),
        html.span([attribute.class("col-product-qty")], [element.text("Cantidad")]),
      ]),

      case displayed_items {
        [] ->
          html.div([attribute.class("empty-list-notice")], [
            element.text(case model.items {
              [] -> "Tu lista está vacía. Añade productos o escanea una foto con 📷"
              _ -> "No hay productos en esta categoría."
            }),
          ])
        _ ->
          html.ul(
            [attribute.class("grocery-items-list")],
            list.map(displayed_items, fn(item) { view_item(model, item) }),
          )
      },
    ]),

    view_share_modal(model, share_url),
    view_switch_modal(model),
    view_delete_modal(model),
  ])
}
