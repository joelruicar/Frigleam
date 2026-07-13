import gleam/int
import gleam/list
import lustre
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub fn main() {
  let app = lustre.simple(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", 5)

  Nil
}

type Model {
  Model(grocery_list: List(String))
}

type Message {
  UserScannedList
  UserAddedItem(List(#(String, String)))
  UserDeletedItem
  UserDeletedList
}

fn view(model: Model) -> Element(Message) {
  let elements =
    list.map(model.grocery_list, fn(string) { element.text(string) })
  html.div([], [
    html.form([event.on_submit(UserAddedItem)], [
      html.input([attribute.name("input_form")]),
      html.button([attribute.type_("submit")], []),
      ..elements
    ]),
  ])
}

fn update(model: Model, message: Message) -> Model {
  case message {
    UserAddedItem(form_item) -> {
      let assert Ok(form_item) = list.key_find(form_item, "input_form")
      Model(grocery_list: [form_item, ..model.grocery_list])
    }
    UserScannedList -> todo
    UserDeletedItem -> todo
    UserDeletedList -> todo
  }
}

fn init(inicial: Int) -> Model {
  Model([])
}
