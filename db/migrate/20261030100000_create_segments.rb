# 会話の区切り。messages から計算できる派生情報なので、いつでも作り直してよい。
# 規則は CLAUDE.md の「会話の区切り」と ConversationSegmenter を参照。
class CreateSegments < ActiveRecord::Migration[8.1]
  def change
    create_table :segments do |t|
      t.string :session_id, null: false
      t.date :segment_date, null: false # 開始時刻の日本時間の暦日
      t.references :first_message, null: false, foreign_key: { to_table: :messages }
      t.references :last_message, null: false, foreign_key: { to_table: :messages }
      t.datetime :started_at, null: false
      t.datetime :ended_at, null: false
      t.string :start_reason, null: false # first / gap / after_end / resume_phrase
      t.string :end_reason, null: false # gap / end_phrase / implicit / open
      t.boolean :resumed, null: false, default: false
      t.references :continued_from, foreign_key: { to_table: :segments, on_delete: :nullify }

      t.timestamps
    end
    add_index :segments, [ :session_id, :first_message_id ], unique: true
    add_index :segments, :segment_date
  end
end
