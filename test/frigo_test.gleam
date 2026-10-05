import categories
import gleam/json
import gleam/option
import gleeunit
import gleeunit/should
import items.{Item, merge_item, parse_scanned_line, sort_items}
import saved_lists.{SavedList}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_scanned_line_simple_test() {
  let #(name, count) = parse_scanned_line("leche 2")
  name |> should.equal("Leche")
  count |> should.equal(2)
}

pub fn parse_scanned_line_with_leading_number_test() {
  let #(name, count) = parse_scanned_line("3 manzanas rojas")
  name |> should.equal("Manzanas rojas")
  count |> should.equal(3)
}

pub fn parse_scanned_line_without_number_defaults_to_one_test() {
  let #(name, count) = parse_scanned_line("platanos de canarias")
  name |> should.equal("Platanos de canarias")
  count |> should.equal(1)
}

pub fn sort_items_puts_unchecked_first_and_alphabetical_test() {
  let item_list = [
    Item("1", "Pan", 1, True, "🥖 Panadería"),
    Item("2", "Tomates", 3, False, "🥬 Frutas y verduras"),
    Item("3", "Aguacates", 2, False, "🥬 Frutas y verduras"),
    Item("4", "Aceite", 1, True, "🥫 Despensa"),
  ]

  let sorted = sort_items(item_list)

  sorted
  |> should.equal([
    Item("3", "Aguacates", 2, False, "🥬 Frutas y verduras"),
    Item("2", "Tomates", 3, False, "🥬 Frutas y verduras"),
    Item("4", "Aceite", 1, True, "🥫 Despensa"),
    Item("1", "Pan", 1, True, "🥖 Panadería"),
  ])
}

pub fn infer_category_test() {
  categories.infer_category("Tofu ahumado") |> should.equal("🌱 Veggie")
  categories.infer_category("Hamburguesa vegana") |> should.equal("🌱 Veggie")
  categories.infer_category("Hummus tradicional") |> should.equal("🌱 Veggie")
  categories.infer_category("Tomates cherry")
  |> should.equal("🥬 Frutas y verduras")
  categories.infer_category("Leche desnatada")
  |> should.equal("🥛 Lácteos y huevos")
  categories.infer_category("Pechuga de pollo")
  |> should.equal("🥩 Carne y pescado")
  categories.infer_category("Pan de molde") |> should.equal("🥖 Panadería")
  categories.infer_category("Detergente lavadora") |> should.equal("🧼 Limpieza")
  categories.infer_category("Helado de vainilla")
  |> should.equal("🧊 Congelados")
  categories.infer_category("Pienso para perros") |> should.equal("🐾 Mascotas")
  categories.infer_category("Pañales dodot") |> should.equal("👶 Bebé")
  categories.infer_category("Ibuprofeno 600")
  |> should.equal("💊 Farmacia y salud")
  categories.infer_category("Pilas AA") |> should.equal("🏠 Hogar y bazar")
  categories.infer_category("Chocolate negro")
  |> should.equal("🍫 Dulces y snacks")
  categories.infer_category("Objeto desconocido 123") |> should.equal("📦 Otros")
}

pub fn merge_item_accumulates_amount_test() {
  let initial = [Item("1", "Manzanas", 2, True, "🥬 Frutas y verduras")]
  let updated = merge_item(initial, "Manzanas", 3, "🥬 Frutas y verduras")

  updated
  |> should.equal([Item("1", "Manzanas", 5, False, "🥬 Frutas y verduras")])
}

pub fn add_recent_limits_to_five_and_moves_to_front_test() {
  let recents = ["a", "b", "c", "d", "e"]
  // Adding existing item "c" moves it to front
  let updated = saved_lists.add_recent(recents, "c")
  updated |> should.equal(["c", "a", "b", "d", "e"])

  // Adding new item pushes out the 5th item
  let updated2 = saved_lists.add_recent(updated, "f")
  updated2 |> should.equal(["f", "c", "a", "b", "d"])
}

pub fn saved_lists_operations_test() {
  let list1 = saved_lists.save_list([], "casa", "Mi Casa")
  saved_lists.is_saved(list1, "casa") |> should.equal(True)
  saved_lists.find_saved_name(list1, "casa")
  |> should.equal(option.Some("Mi Casa"))

  // Rename list
  let renamed = saved_lists.rename_saved_list(list1, "casa", "Casa de Verano")
  saved_lists.find_saved_name(renamed, "casa")
  |> should.equal(option.Some("Casa de Verano"))

  // Remove list
  let empty = saved_lists.remove_saved_list(renamed, "casa")
  saved_lists.is_saved(empty, "casa") |> should.equal(False)
}

pub fn saved_lists_serialization_test() {
  let sample = [
    SavedList("casa", "Mi Casa"),
    SavedList("trabajo", "Oficina"),
  ]
  let encoded = json.to_string(saved_lists.saved_lists_writer(sample))
  let decoded = json.parse(encoded, saved_lists.saved_lists_reader())
  decoded |> should.equal(Ok(sample))
}

pub fn recents_serialization_test() {
  let sample = ["casa", "finde", "frigo-1234"]
  let encoded = json.to_string(saved_lists.recents_writer(sample))
  let decoded = json.parse(encoded, saved_lists.recents_reader())
  decoded |> should.equal(Ok(sample))
}
