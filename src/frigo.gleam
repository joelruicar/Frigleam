import gleam/int
import gleam/list
import gleam/string
import lustre
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub fn main() {
  let app = lustre.simple(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", 0)
  Nil
}

type Model {
  Model(grocery_list: List(#(String, Int, Bool)))
}

type Message {
  UserScannedList
  UserAddedItem(List(#(String, String)))
  UserDeletedItem(String)
  UserToggledItem(String)
  UserDeletedList
}

fn view(model: Model) -> Element(Message) {
  let items =
    list.map(model.grocery_list, fn(item) {
      let #(name, count, done) = item
      html.li([attribute.class("grocery-item")], [
        html.input([
          attribute.type_("checkbox"),
          attribute.checked(done),
          event.on_click(UserToggledItem(name)),
        ]),
        html.span([attribute.classes([#("crossed", done)])], [
          element.text(string.concat([int.to_string(count), " ", name])),
        ]),
        html.button(
          [
            attribute.class("delete-btn"),
            event.on_click(UserDeletedItem(name)),
          ],
          [element.text("X")],
        ),
      ])
    })

  html.div([], [
    html.form([attribute.class("form"), event.on_submit(UserAddedItem)], [
      html.input([attribute.name("input_form"), attribute.class("input")]),
      html.input([
        attribute.name("input_count"),
        attribute.type_("number"),
        attribute.class("input-number"),
        attribute.min("1"),
        attribute.value("1"),
      ]),
      html.button([attribute.type_("submit"), attribute.class("btn")], [
        element.text("Agregar"),
      ]),
    ]),
    html.ul([attribute.class("list")], items),
  ])
}

fn update(model: Model, message: Message) -> Model {
  case message {
    UserAddedItem(form_item) -> {
      let assert Ok(name) = list.key_find(form_item, "input_form")
      let assert Ok(count_str) = list.key_find(form_item, "input_count")
      let assert Ok(count) = int.parse(count_str)
      let formatted_name = string.capitalise(name)

      let item_exists =
        list.any(model.grocery_list, fn(item) { item.0 == formatted_name })

      let updated_list = case item_exists {
        True ->
          list.map(model.grocery_list, fn(item) {
            case item.0 == formatted_name {
              True -> #(item.0, item.1 + count, False)
              False -> item
            }
          })
        False -> [#(formatted_name, count, False), ..model.grocery_list]
      }

      let sorted_list =
        list.sort(updated_list, by: fn(a, b) { string.compare(a.0, b.0) })
      Model(grocery_list: sorted_list)
    }

    UserScannedList -> model

    UserDeletedItem(name) -> {
      let filtered_list =
        list.filter(model.grocery_list, fn(item) { item.0 != name })
      Model(grocery_list: filtered_list)
    }

    UserToggledItem(name) -> {
      let toggled =
        list.map(model.grocery_list, fn(item) {
          case item.0 == name {
            True -> {
              let new_done = case item.2 {
                True -> False
                False -> True
              }
              #(item.0, item.1, new_done)
            }
            False -> item
          }
        })
      Model(grocery_list: toggled)
    }

    UserDeletedList -> Model([])
  }
}

fn init(_inicial: Int) -> Model {
  Model([])
}
