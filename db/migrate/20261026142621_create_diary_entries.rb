class CreateDiaryEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :diary_entries do |t|
      t.date :entry_date, null: false
      t.text :body_kanbun
      t.text :body_kundoku

      t.timestamps
    end
    add_index :diary_entries, :entry_date, unique: true
  end
end
