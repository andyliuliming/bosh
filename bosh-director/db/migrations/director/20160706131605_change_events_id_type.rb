Sequel.migration do
  change do
    if [:mssql].include?(database_type)
        run <<-SQL
          declare @schema_name nvarchar(256)
          declare @table_name nvarchar(256)
          declare @col_name nvarchar(256)
          declare @Command  nvarchar(1000)
          set @table_name = N'events'
          set @col_name = N'id'
          select @Command = 'ALTER TABLE ' + '' + @table_name + ' drop constraint ' + d.name
          from sys.tables t
              join sys.key_constraints d
              on d.parent_object_id = t.object_id
              join sys.columns c
              on c.object_id = t.object_id
          where t.name = @table_name and c.name = @col_name and d.type = 'PK'

          execute (@Command)
          SQL
        alter_table :events do
          set_column_type :id, Bignum
          set_column_type :parent_id, Bignum
          add_primary_key [:id]
        end
    else
      unless [:sqlite].include?(adapter_scheme)
        set_column_type :events, :id, Bignum
        set_column_type :events, :parent_id, Bignum
      end
    end
  end
end
