Sequel.migration do
  change do
    if Sequel::Model.db.database_type == :mssql
      table_name = schema_and_table('instances').compact.join('.')
      constraint_name = self[Sequel[:sys][:default_constraints]].
        where{{:parent_object_id => Sequel::SQL::Function.new(:object_id, table_name), col_name(:parent_object_id, :parent_column_id) => 'post_start_completed'.to_s}}.
      get(:name)
      alter_table :instances do
          drop_constraint constraint_name
      end
    end
    alter_table :instances do
      rename_column :post_start_completed, :update_completed      
      set_column_default :update_completed, false
    end
  end
end
