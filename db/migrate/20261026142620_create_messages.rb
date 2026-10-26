class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    # 原本。追記のみで、更新・削除はしない（下のトリガーでDB側でも拒否する）。
    create_table :messages do |t|
      t.string :source, null: false
      t.string :external_id, null: false
      t.string :session_id, null: false
      t.string :role, null: false
      t.text :body, null: false
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :messages, [ :source, :external_id ], unique: true
    add_index :messages, :session_id
    add_index :messages, :occurred_at

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION messages_append_only() RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION 'messages is append-only (% rejected)', TG_OP;
          END;
          $$ LANGUAGE plpgsql;

          CREATE TRIGGER messages_no_update_delete
            BEFORE UPDATE OR DELETE ON messages
            FOR EACH ROW EXECUTE FUNCTION messages_append_only();

          CREATE TRIGGER messages_no_truncate
            BEFORE TRUNCATE ON messages
            FOR EACH STATEMENT EXECUTE FUNCTION messages_append_only();
        SQL
      end
      dir.down do
        execute <<~SQL
          DROP TRIGGER messages_no_truncate ON messages;
          DROP TRIGGER messages_no_update_delete ON messages;
          DROP FUNCTION messages_append_only();
        SQL
      end
    end
  end
end
