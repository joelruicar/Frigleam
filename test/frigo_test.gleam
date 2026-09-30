import frigo.{CheckedItem, UncheckedItem, is_checked, parse_scanned_line, sort_items}
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
    CheckedItem("Pan", 1),
    UncheckedItem("Tomates", 3),
    UncheckedItem("Aguacates", 2),
    CheckedItem("Aceite", 1),
  ]

  let sorted = sort_items(items)

  sorted
  |> should.equal([
    UncheckedItem("Aguacates", 2),
    UncheckedItem("Tomates", 3),
    CheckedItem("Aceite", 1),
    CheckedItem("Pan", 1),
  ])
}

pub fn is_checked_test() {
  is_checked(CheckedItem("Queso", 1)) |> should.be_true
  is_checked(UncheckedItem("Queso", 1)) |> should.be_false
}
