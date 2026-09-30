import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string

pub type Item {
  Item(id: String, name: String, amount: Int, checked: Bool, category: String)
}

pub fn new_id() -> String {
  "item-"
  <> int.to_base16(int.random(2_147_483_647))
  <> int.to_base16(int.random(2_147_483_647))
}

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

/// Adds `amount` to an existing item or prepends a new one.
pub fn merge_item(
  items: List(Item),
  name: String,
  amount: Int,
  category: String,
) -> List(Item) {
  case list.any(items, fn(item) { item.name == name }) {
    True ->
      list.map(items, fn(item) {
        case item.name == name {
          True -> Item(..item, amount: item.amount + amount, checked: False)
          False -> item
        }
      })
    False -> [Item(new_id(), name, amount, False, category), ..items]
  }
}

pub fn parse_scanned_line(line: String) -> #(String, Int) {
  let words =
    line
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })

  let amount =
    words
    |> list.find_map(int.parse)
    |> result.unwrap(1)

  let name_words =
    list.filter(words, fn(word) { result.is_error(int.parse(word)) })

  case name_words {
    [] -> #("", amount)
    _ -> #(string.capitalise(string.join(name_words, " ")), amount)
  }
}

pub fn reader() {
  decode.list({
    use name <- decode.field("name", decode.string)
    use id <- decode.optional_field("id", "legacy-" <> name, decode.string)
    use amount <- decode.field("number", decode.int)
    use checked <- decode.field("checked", decode.bool)
    use category <- decode.optional_field("category", "📦 Otros", decode.string)
    decode.success(Item(id:, name:, amount:, checked:, category:))
  })
}

pub fn writer(items: List(Item)) {
  use item <- json.array(items)
  json.object([
    #("id", json.string(item.id)),
    #("checked", json.bool(item.checked)),
    #("name", json.string(item.name)),
    #("number", json.int(item.amount)),
    #("category", json.string(item.category)),
  ])
}
