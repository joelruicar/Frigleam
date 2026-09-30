import frigo.{Item, parse_scanned_line, sort_items}
import gleeunit
import gleeunit/should

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
  let items = [
    Item("Pan", 1, True),
    Item("Tomates", 3, False),
    Item("Aguacates", 2, False),
    Item("Aceite", 1, True),
  ]

  let sorted = sort_items(items)

  sorted
  |> should.equal([
    Item("Aguacates", 2, False),
    Item("Tomates", 3, False),
    Item("Aceite", 1, True),
    Item("Pan", 1, True),
  ])
}
