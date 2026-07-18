import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
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

type Model {
  Model(items: varasto.TypedStorage(List(Item)), scanning: Bool)
}

type Item {
  CheckedItem(name: String, amount: Int)
  UncheckedItem(name: String, amount: Int)
}

type Message {
  UserSelectedImage(dynamic.Dynamic)
  UserScannedText(String)
  UserAddedItem(List(#(String, String)))
  UserDeletedItem(String)
  UserToggledItem(String)
  UserDeletedList
}

// -- FFI: definidas en frigo_ffi.mjs, en la misma carpeta que este archivo --

@external(javascript, "./frigo_ffi.mjs", "get_file_from_input")
fn get_file_from_input(event: dynamic.Dynamic) -> dynamic.Dynamic

@external(javascript, "./frigo_ffi.mjs", "is_null_file")
fn is_null_file(file: dynamic.Dynamic) -> Bool

@external(javascript, "./frigo_ffi.mjs", "scan_image")
fn do_scan_image(file: dynamic.Dynamic, dispatch: fn(String) -> Nil) -> Nil

fn view(model: Model) -> Element(Message) {
  let assert Ok(items) = varasto.get(model.items, "items")
  let items =
    list.map(items, fn(item: Item) {
      let done = is_checked(item)
      html.li([attribute.class("grocery-item")], [
        html.input([
          attribute.type_("checkbox"),
          attribute.checked(done),
          event.on_click(UserToggledItem(item.name)),
        ]),
        html.span([attribute.classes([#("crossed", done)])], [
          element.text(
            string.concat([int.to_string(item.amount), " ", item.name]),
          ),
        ]),
        html.button(
          [
            attribute.class("delete-btn"),
            event.on_click(UserDeletedItem(item.name)),
          ],
          [element.text("X")],
        ),
      ])
    })

  html.div([], [
    html.form([attribute.class("form"), event.on_submit(UserAddedItem)], [
      html.input([
        attribute.name("input_form"),
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
        element.text("Add"),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("btn"),
          event.on_click(UserDeletedList),
        ],
        [
          element.text("Delete"),
        ],
      ),
    ]),
    html.div([attribute.class("scan-section")], [
      html.label(
        [attribute.class("btn"), attribute.attribute("for", "scan-input")],
        [
          element.text(case model.scanning {
            True -> "Escaneando..."
            False -> "📷 Escanear lista"
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
    html.ul([attribute.class("list")], items),
  ])
}

fn is_checked(item: Item) -> Bool {
  let done = case item {
    CheckedItem(..) -> True
    UncheckedItem(..) -> False
  }
  done
}

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case message {
    UserAddedItem(form_item) -> {
      let assert Ok(name) = list.key_find(form_item, "input_form")
      let assert Ok(count_str) = list.key_find(form_item, "input_count")
      let assert Ok(count) = int.parse(count_str)
      let formatted_name = string.capitalise(name)
      #(
        model,
        effect.from(fn(_) {
          let assert Ok(items) = varasto.get(model.items, "items")

          let item_exists =
            list.any(items, fn(item) { item.name == formatted_name })

          let updated_list = case item_exists {
            True ->
              list.map(items, fn(item) {
                case item.name == formatted_name {
                  True -> UncheckedItem(item.name, item.amount + count)
                  False -> item
                }
              })
            False -> [UncheckedItem(formatted_name, count), ..items]
          }

          let sorted_list =
            list.sort(updated_list, by: fn(a, b) {
              string.compare(a.name, b.name)
            })
          let _ = varasto.set(model.items, "items", sorted_list)
          Nil
        }),
      )
    }

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
      #(
        Model(..model, scanning: False),
        effect.from(fn(_) {
          let assert Ok(items) = varasto.get(model.items, "items")

          let lines =
            text
            |> string.split("\n")
            |> list.map(string.trim)
            |> list.filter(fn(l) { l != "" })
            |> list.map(string.capitalise)

          let updated_list =
            list.fold(lines, items, fn(acc, name) {
              let item_exists = list.any(acc, fn(item) { item.name == name })
              case item_exists {
                True ->
                  list.map(acc, fn(item) {
                    case item.name == name {
                      True -> UncheckedItem(item.name, item.amount + 1)
                      False -> item
                    }
                  })
                False -> [UncheckedItem(name, 1), ..acc]
              }
            })

          let sorted_list =
            list.sort(updated_list, by: fn(a, b) {
              string.compare(a.name, b.name)
            })
          let _ = varasto.set(model.items, "items", sorted_list)
          Nil
        }),
      )
    }

    UserDeletedItem(name) -> {
      #(
        model,
        effect.from(fn(_) {
          let assert Ok(items) = varasto.get(model.items, "items")

          let filtered_list =
            list.filter(items, fn(item: Item) { item.name != name })
          let _ = varasto.set(model.items, "items", filtered_list)
          Nil
        }),
      )
    }

    UserDeletedList -> {
      #(
        model,
        effect.from(fn(_) {
          let _ = varasto.set(model.items, "items", [])
          Nil
        }),
      )
    }

    UserToggledItem(name) -> {
      #(
        model,
        effect.from(fn(_) {
          let assert Ok(items) = varasto.get(model.items, "items")
          let toggled =
            list.map(items, fn(item: Item) {
              case item.name == name {
                True -> {
                  let _ = case item {
                    CheckedItem(name:, amount:) -> UncheckedItem(name:, amount:)
                    UncheckedItem(name:, amount:) -> CheckedItem(name:, amount:)
                  }
                }
                False -> item
              }
            })
          let modified_list = {
            let unchecked =
              list.sort(
                list.filter(toggled, fn(item) { !is_checked(item) }),
                by: fn(a, b) { string.compare(a.name, b.name) },
              )
            let checked = list.filter(toggled, is_checked)
            list.append(unchecked, checked)
          }
          let _ = varasto.set(model.items, "items", modified_list)
          Nil
        }),
      )
    }
  }
}

fn init(_inicial: Int) -> #(Model, effect.Effect(Message)) {
  let assert Ok(local) = varasto.local()

  let s = varasto.new(local, reader(), writer)
  let _ = case varasto.get(s, "items") {
    Error(_) -> varasto.set(s, "items", [])
    Ok(_) -> Ok(Nil)
  }

  #(Model(items: s, scanning: False), effect.none())
}

fn reader() {
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

fn writer(lista_item: List(Item)) {
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
