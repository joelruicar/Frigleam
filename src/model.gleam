import gleam/dynamic
import gleam/option.{type Option}
import items.{type Item}
import varasto

pub type Model {
  Model(
    items_storage: varasto.TypedStorage(List(Item)),
    items: List(Item),
    scanning: Bool,
    editing: Option(String),
    confirm_delete_list: Bool,
    draft_name: String,
    draft_amount: String,
    draft_category: String,
    collapsed_sections: List(String),
    room_id: String,
    connection_status: ConnectionStatus,
    show_share_modal: Bool,
    show_switch_modal: Bool,
    switch_room_input: String,
    copied_toast: Bool,
  )
}

pub type ConnectionStatus {
  Connecting
  Connected
  Disconnected
}

pub type Message {
  Noop
  UserAddedItem(List(#(String, String)))
  UserDeletedItem(String)
  UserToggledItem(String)
  UserAskedToDeleteList
  UserCancelledDeleteList
  UserConfirmedDeleteList
  UserClickedItem(name: String, amount: Int, category: String)
  UserChangedDraftName(String)
  UserChangedDraftAmount(String)
  UserChangedDraftCategory(String)
  UserConfirmedEdit
  UserToggledSection(category: String)
  UserSelectedImage(dynamic.Dynamic)
  UserScannedText(String)
  RemoteItemsReceived(dynamic.Dynamic)
  ConnectionStatusChanged(Bool)
  UserOpenedShareModal
  UserClosedShareModal
  UserClickedNativeShare
  UserClickedCopyLink
  UserOpenedSwitchModal
  UserClosedSwitchModal
  UserChangedSwitchInput(String)
  UserConfirmedSwitchRoom
  UserGenerateRandomRoom
}
