import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub type SavedList {
  SavedList(room_id: String, name: String)
}

pub fn saved_lists_reader() -> decode.Decoder(List(SavedList)) {
  decode.list({
    use room_id <- decode.field("room_id", decode.string)
    use name <- decode.field("name", decode.string)
    decode.success(SavedList(room_id: room_id, name: name))
  })
}

pub fn saved_lists_writer(lists: List(SavedList)) -> json.Json {
  use item <- json.array(lists)
  json.object([
    #("room_id", json.string(item.room_id)),
    #("name", json.string(item.name)),
  ])
}

pub fn recents_reader() -> decode.Decoder(List(String)) {
  decode.list(decode.string)
}

pub fn recents_writer(recents: List(String)) -> json.Json {
  json.array(recents, json.string)
}

/// Adds a room_id to recents (moved to head, deduplicated, maximum 5).
pub fn add_recent(recents: List(String), room_id: String) -> List(String) {
  let clean = string.trim(room_id)
  case clean {
    "" -> recents
    _ ->
      [clean, ..list.filter(recents, fn(id) { id != clean })]
      |> list.take(5)
  }
}

/// Saves a list to saved lists. If it already exists, updates its name.
pub fn save_list(
  saved: List(SavedList),
  room_id: String,
  name: String,
) -> List(SavedList) {
  let clean_id = string.trim(room_id)
  let clean_name = string.trim(name)
  let display_name = case clean_name {
    "" -> clean_id
    other -> other
  }
  case clean_id {
    "" -> saved
    _ ->
      case list.any(saved, fn(item) { item.room_id == clean_id }) {
        True ->
          list.map(saved, fn(item) {
            case item.room_id == clean_id {
              True -> SavedList(room_id: clean_id, name: display_name)
              False -> item
            }
          })
        False ->
          list.append(saved, [SavedList(room_id: clean_id, name: display_name)])
      }
  }
}

/// Removes a list from saved lists.
pub fn remove_saved_list(
  saved: List(SavedList),
  room_id: String,
) -> List(SavedList) {
  list.filter(saved, fn(item) { item.room_id != room_id })
}

/// Renames an existing saved list. If new_name is blank, defaults to room_id.
pub fn rename_saved_list(
  saved: List(SavedList),
  room_id: String,
  new_name: String,
) -> List(SavedList) {
  let clean_name = string.trim(new_name)
  let display_name = case clean_name {
    "" -> room_id
    other -> other
  }
  list.map(saved, fn(item) {
    case item.room_id == room_id {
      True -> SavedList(room_id: item.room_id, name: display_name)
      False -> item
    }
  })
}

/// Checks whether a room_id is currently saved.
pub fn is_saved(saved: List(SavedList), room_id: String) -> Bool {
  list.any(saved, fn(item) { item.room_id == room_id })
}

/// Finds the custom display name for a room_id if it was saved.
pub fn find_saved_name(
  saved: List(SavedList),
  room_id: String,
) -> Option(String) {
  list.find(saved, fn(item) { item.room_id == room_id })
  |> result.map(fn(item) { item.name })
  |> option.from_result
}
