# diary_links に、リンクの種類（link_kind）と、どの項目のリンクか（item_key。例「決定:2」）を足す。
# link_kind: source（引用から特定した人間の発言）/ preceding_assistant_candidate（直前の assistant 発言。候補）。
# item_key が NULL の（ダイアリー全体への）リンクも1組につき1本にするため、一意索引は nulls_not_distinct。
class AddLinkKindToDiaryLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :diary_links, :link_kind, :string, null: false, default: "source"
    add_column :diary_links, :item_key, :string
    remove_index :diary_links, column: %i[ diary_entry_id message_id ], unique: true
    add_index :diary_links, %i[ diary_entry_id item_key message_id link_kind ],
      unique: true, nulls_not_distinct: true, name: "index_diary_links_on_identity"
  end
end
