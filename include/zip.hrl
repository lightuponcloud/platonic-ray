%% ZIP format constants
-define(LOCAL_FILE_HEADER_SIGNATURE, 16#04034b50).
-define(CENTRAL_DIR_SIGNATURE, 16#02014b50).
-define(END_OF_CENTRAL_DIR_SIGNATURE, 16#06054b50).
-define(ZIP64_END_OF_CENTRAL_DIR_SIGNATURE, 16#06064b50).
-define(ZIP64_END_OF_CENTRAL_DIR_LOCATOR_SIGNATURE, 16#07064b50).
-define(DATA_DESCRIPTOR_SIGNATURE, 16#08074b50).
-define(VERSION_ZIP64, 45).
-define(COMPRESSION_STORE, 0).

%% General purpose bit flag
-define(USE_DATA_DESCRIPTOR, 16#0008).  %% Bit 3 for data descriptor

-define(CHUNK_SIZE, 1048576). % 1MB chunks

-define(COMPRESSION_CONFIG, [
    %% Already compressed formats - store only
    {[<<".zip">>, <<".gz">>, <<".xz">>, <<".7z">>, <<".rar">>,
      <<".mp3">>, <<".mp4">>, <<".avi">>, <<".mkv">>, <<".mov">>,
      <<".jpg">>, <<".jpeg">>, <<".png">>, <<".webp">>, <<".heic">>,
      <<".aac">>, <<".ogg">>, <<".webm">>],
     [{level, 0}, {strategy, none}]},  % no compression

    %% Text and source code - high compression
    {[<<".txt">>, <<".log">>, <<".csv">>, <<".md">>, <<".json">>,
      <<".xml">>, <<".yml">>, <<".yaml">>, <<".html">>, <<".htm">>,
      <<".css">>, <<".js">>, <<".jsx">>, <<".ts">>, <<".tsx">>,
      <<".php">>, <<".rb">>, <<".py">>, <<".java">>, <<".c">>,
      <<".cpp">>, <<".h">>, <<".hpp">>, <<".cs">>, <<".sql">>,
      <<".sh">>, <<".bash">>, <<".erl">>, <<".hrl">>, <<".ex">>,
      <<".exs">>, <<".go">>, <<".rs">>, <<".dart">>, <<".lua">>,
      <<".conf">>, <<".ini">>, <<".properties">>],
     [{level, 9}, {strategy, default}]},  % maximum compression

    %% Office documents - medium-high compression
    {[<<".doc">>, <<".docx">>, <<".xls">>, <<".xlsx">>, 
      <<".ppt">>, <<".pptx">>, <<".odt">>, <<".ods">>, 
      <<".pdf">>, <<".rtf">>, <<".tex">>],
     [{level, 7}, {strategy, default}]},

    %% Binary files - medium compression
    {[<<".exe">>, <<".dll">>, <<".so">>, <<".dylib">>,
      <<".bin">>, <<".dat">>, <<".db">>, <<".sqlite">>],
      [{level, 5}, {strategy, filtered}]},

    %% Default for unknown types - balanced
    {[<<".default">>], [{level, 6}, {strategy, default}]}
]).
