class AddRawToMessages < ActiveRecord::Migration[8.1]
  def change
    # 取り込み元の発言をそのまま残す（thinking / tool_use など、body に入れないものもここに残る）。
    add_column :messages, :raw, :jsonb, null: false, default: {}
  end
end
