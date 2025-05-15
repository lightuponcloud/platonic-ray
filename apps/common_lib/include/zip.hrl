%% ZIP format constants
-define(LOCAL_FILE_HEADER_SIGNATURE, 16#04034b50).
-define(CENTRAL_DIR_SIGNATURE, 16#02014b50).
-define(END_OF_CENTRAL_DIR_SIGNATURE, 16#06054b50).
-define(ZIP64_END_OF_CENTRAL_DIR_SIGNATURE, 16#06064b50).
-define(ZIP64_END_OF_CENTRAL_DIR_LOCATOR_SIGNATURE, 16#07064b50).
-define(DATA_DESCRIPTOR_SIGNATURE, 16#08074b50).
-define(COMPRESSION_STORE, 0).
-define(COMPRESSION_DEFLATE, 8).    % DEFLATE compression (RFC 1951)

% DEFLATE compression levels for zlib
-define(NO_COMPRESSION, 0).         % zlib: no compression
-define(BEST_SPEED, 1).            % zlib: fastest compression
-define(BEST_COMPRESSION, 9).       % zlib: best compression
-define(DEFAULT_COMPRESSION, 6).    % zlib: default level

% DEFLATE compression strategies
-define(FILTERED, 1).      % Filtered for data produced by a filter/predictor
-define(HUFFMAN_ONLY, 2).  % Force Huffman encoding only (no string match)
-define(RLE, 3).          % Limit match distances to one (run-length encoding)
-define(FIXED, 4).        % Prevent dynamic Huffman codes

%% Add UTF-8 related constants
-define(UTF8_FLAG, 16#0800).  % General purpose bit 11 for UTF-8
-define(UNICODE_PATH_EXTRA_ID, 16#7075).  % Info-ZIP Unicode Path Extra Field

-define(ZIP64_EXTRA_ID, 16#0001).  % ZIP64 Extra Field ID
-define(VERSION_ZIP64, 45).  %% Version 4.5 for ZIP64

% Constants for the flags
-define(USE_DATA_DESCRIPTOR, 16#0008).    % Bit 3
-define(USE_UTF8, 16#0800).              % Bit 11

-define(CHUNK_SIZE, 1048576). %% 1MB chunks

-define(MADE_BY_UNIX, 16#0300).  %% Version made by (UNIX, v3.0)

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
