Sequel.migration do
  change do
    add_column :director_attributes, :temp_name, String, null: true
    self[:director_attributes].update(temp_name: :name)

    if Sequel::Model.db.database_type == :mssql
        run <<-SQL
          declare @schema_name nvarchar(256)
          declare @table_name nvarchar(256)
          declare @col_name nvarchar(256)
          declare @Command  nvarchar(1000)
          set @table_name = N'director_attributes'
          set @col_name = N'name'
          select @Command = 'ALTER TABLE ' + '' + @table_name + ' drop constraint ' + d.name
          from sys.tables t
              join sys.key_constraints d
              on d.parent_object_id = t.object_id
              join sys.columns c
              on c.object_id = t.object_id
          where t.name = @table_name and c.name = @col_name and d.type = 'PK'
          execute (@Command)
        SQL
    end
    alter_table :director_attributes do      
      drop_column :name
      rename_column :temp_name, :name
      set_column_not_null :name
      add_index [:name], unique:true, name: 'unique_attribute_name'
      add_primary_key :id
    end
  end
end
