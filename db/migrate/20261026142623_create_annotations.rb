class CreateAnnotations < ActiveRecord::Migration[8.1]
  def change
    create_table :annotations do |t|
      t.references :annotatable, polymorphic: true, null: false
      t.text :body, null: false

      t.timestamps
    end
  end
end
