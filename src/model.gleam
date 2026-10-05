import gleam/dynamic
import gleam/option.{type Option}
import items.{type Item}
import saved_lists.{type SavedList}
import varasto

pub type Model {
  Model(
    items_storage: varasto.TypedStorage(List(Item)),
    items: List(Item),
    saved_lists_storage: varasto.TypedStorage(List(SavedList)),
    saved_lists: List(SavedList),
    recent_lists_storage: varasto.TypedStorage(List(String)),
    recent_lists: List(String),
    editing_saved_list: Option(String),
    draft_saved_name: String,
    scanning: Bool,
    editing: Option(String),
    confirm_delete_list: Bool,
    draft_name: String,
    draft_amount: String,
    draft_category: String,
    collapsed_sections: List(String),
    selected_tab: String,
    room_id: String,
    connection_status: ConnectionStatus,
    ocr_error: Option(String),
    show_share_modal: Bool,
    show_switch_modal: Bool,
    switch_room_input: String,
    copied_toast: Bool,
    show_cart_menu: Bool,
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
  UserClickedItem(id: String, name: String, amount: Int, category: String)
  UserChangedDraftName(String)
  UserChangedDraftAmount(String)
  UserChangedDraftCategory(String)
  UserConfirmedEdit
  UserSelectedTab(String)
  UserToggledSection(category: String)
  UserSelectedImage(dynamic.Dynamic)
  UserScannedText(String)
  UserScanFailed(String)
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
  UserToggledCartMenu
  UserSavedCurrentList
  UserSavedList(room_id: String)
  UserRemovedSavedList(room_id: String)
  UserStartedRenamingSavedList(room_id: String, current_name: String)
  UserChangedDraftSavedName(String)
  UserConfirmedRenameSavedList(room_id: String)
  UserCancelledRenameSavedList
  UserSelectedRoom(room_id: String)
}
