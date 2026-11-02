# 座を塊に分けて A を呼んだときの、塊ごとの記録。LLM の生の出力と、所要時間・トークン数を残す。
# 中断から再開できるようにすることと、規則だけを変えたとき LLM を呼ばずに後処理だけやり直すことが目的。
# raw_output は text（JSON が崩れた出力も、そのまま残すため）。
class CreateDiaryChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :diary_chunks do |t|
      t.references :segment, null: false, foreign_key: true
      t.integer :chunk_index, null: false
      t.string :input_digest, null: false
      t.string :model, null: false
      t.string :model_digest             # /api/tags の digest（同じ名前のモデルが入れ替わったかを見る）
      t.string :prompt_version, null: false
      t.string :status, null: false, default: "pending" # pending / succeeded / failed
      t.text :raw_output
      t.string :error_kind
      t.text :error_message
      t.integer :attempts, null: false, default: 0
      t.integer :seed
      t.string :done_reason
      t.integer :prompt_eval_count
      t.integer :eval_count
      t.integer :total_duration_ms
      t.integer :prompt_eval_duration_ms
      t.integer :eval_duration_ms

      t.timestamps
    end
    add_index :diary_chunks, %i[ segment_id chunk_index input_digest model prompt_version ], unique: true, name: "index_diary_chunks_on_identity"
    add_index :diary_chunks, :status
  end
end
