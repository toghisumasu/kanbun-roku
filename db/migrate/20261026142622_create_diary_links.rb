class CreateDiaryLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :diary_links do |t|
      t.references :diary_entry, null: false, foreign_key: { on_delete: :cascade }
      t.references :message, null: false, foreign_key: true

      t.timestamps
    end
    add_index :diary_links, [ :diary_entry_id, :message_id ], unique: true
  end
end
