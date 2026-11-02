# ダイアリーを座（segment）単位にする。1日に複数の座があるので、entry_date の一意制約は外す。
# diary_entries は原本からの派生物。行があるときは、座との対応を決められないので、勝手に変えず止める。
class MakeDiaryEntriesPerSegment < ActiveRecord::Migration[8.1]
  def up
    if select_value("SELECT COUNT(*) FROM diary_entries").to_i.positive?
      raise "diary_entries に行があります。座との対応を決めてから移行してください"
    end

    add_reference :diary_entries, :segment, null: false, foreign_key: true, index: { unique: true }
    remove_index :diary_entries, :entry_date
    add_index :diary_entries, :entry_date

    add_column :diary_entries, :note, :jsonb, null: false, default: {}            # 後処理後の A の出力
    add_column :diary_entries, :validation, :jsonb, null: false, default: {}      # 引用の検証結果
    add_column :diary_entries, :model, :string, null: false
    add_column :diary_entries, :prompt_version, :string, null: false
    add_column :diary_entries, :rule_version, :string, null: false
    add_column :diary_entries, :input_digest, :string, null: false
    add_column :diary_entries, :generated_at, :datetime
  end

  def down
    remove_column :diary_entries, :generated_at
    remove_column :diary_entries, :input_digest
    remove_column :diary_entries, :rule_version
    remove_column :diary_entries, :prompt_version
    remove_column :diary_entries, :model
    remove_column :diary_entries, :validation
    remove_column :diary_entries, :note
    remove_index :diary_entries, :entry_date
    add_index :diary_entries, :entry_date, unique: true
    remove_reference :diary_entries, :segment, foreign_key: true, index: { unique: true }
  end
end
