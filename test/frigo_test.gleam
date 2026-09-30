import categories
import gleeunit
import gleeunit/should
import items.{Item, merge_item, parse_scanned_line, sort_items}

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
    Item("Pan", 1, True, "🥖 Panadería"),
    Item("Tomates", 3, False, "🥬 Frutas y verduras"),
    Item("Aguacates", 2, False, "🥬 Frutas y verduras"),
    Item("Aceite", 1, True, "🥫 Despensa"),
  ]

  let sorted = sort_items(item_list)

  sorted
  |> should.equal([
    Item("Aguacates", 2, False, "🥬 Frutas y verduras"),
    Item("Tomates", 3, False, "🥬 Frutas y verduras"),
    Item("Aceite", 1, True, "🥫 Despensa"),
    Item("Pan", 1, True, "🥖 Panadería"),
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
  let initial = [Item("Manzanas", 2, True, "🥬 Frutas y verduras")]
  let updated = merge_item(initial, "Manzanas", 3, "🥬 Frutas y verduras")

  updated
  |> should.equal([Item("Manzanas", 5, False, "🥬 Frutas y verduras")])
}
