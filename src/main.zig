const z = @import( "std" );
const folders = @import( "known_folders" );
var gpa = z.heap.GeneralPurposeAllocator( .{ .thread_safe = true } ){};
const alloc = gpa.allocator();

const bufprint = z.fmt.bufPrint;
const allocprint = z.fmt.allocPrint;
const ArrayList = z.ArrayList;

var paths = [_][]const u8{
  "/usr/share/applications",
  "/usr/local/share/applications",
  "~/.local/share/applications",
};

const FsEntry = struct {
  fn deinit( s: *const FsEntry ) void {
    alloc.free( s.path );
    alloc.free( s.name );
  }

  path: []const u8,
  name: []const u8,
  is_dir: bool
};

const XdgEntry = struct {
  fn deinit( s: *const XdgEntry ) void {
    alloc.free( s.path );
    alloc.free( s.name );
    alloc.free( s.desc );
    alloc.free( s.exec );
  }

  path: []const u8,
  name: []const u8,
  desc: []const u8,
  exec: []const u8,
};

pub fn checkSymlink( path: []const u8 ) !void {
  const link_path_buf = try alloc.alloc( u8, z.fs.max_path_bytes );
  var link_path = try z.fs.readLinkAbsolute( path, link_path_buf[0..z.fs.max_path_bytes] );

  const is_abs = z.fs.path.isAbsolute( link_path );
  if( !is_abs )
    link_path = try z.fs.path.resolve( alloc, &[_][]const u8{ path, "..", link_path } );

  defer if( !is_abs ) alloc.free( link_path );

  const f = try z.fs.openFileAbsolute( link_path, .{} );
  defer f.close();

  const meta = try f.metadata();
  if( meta.kind() != .file )
    return error.NotAFile;
}

pub fn openDir( path: []const u8 ) !ArrayList( FsEntry ) {
  var handle = try z.fs.openDirAbsolute( path, .{ .iterate = true, .no_follow = false } );
  defer handle.close();

  var list = ArrayList( FsEntry ).init( alloc );

  var iter = handle.iterate();
  while( try iter.next() ) |entry| {
    if( !z.mem.endsWith( u8, entry.name, ".desktop" ) )
      continue;

    const path_buf = try alloc.alloc( u8, entry.name.len + path.len + 1 );
    const name = try alloc.dupe( u8, entry.name );
    const entry_path = try bufprint( path_buf, "{s}/{s}", .{path, entry.name} );

    if( entry.kind == .sym_link ) {
      checkSymlink( entry_path ) catch continue;
    }

    const fs_entry = FsEntry{
      .name = name,
      .path = entry_path,
      .is_dir = entry.kind == .directory
    };

    list.append( fs_entry ) catch {};
  }

  return list;
}

pub fn parseXDGEntry( contents: []const u8, path: []const u8 ) !XdgEntry {
  var i: u32 = 0;
  var s: u32 = 0;

  var name: ?[]const u8 = null;
  var exec: ?[]const u8 = null;
  var desc: ?[]const u8 = null;

  for( contents ) |c| {
    if( c == '\n' ) {
      const line = contents[s..i];
      if( name == null ) {
        if( z.mem.startsWith( u8, line, "Name=" ) )
          name = try alloc.dupe( u8, line[5..line.len] );
      }
      if( exec == null ) {
        if( z.mem.startsWith( u8, line, "Exec=" ) )
          exec = try alloc.dupe( u8, line[5..line.len] );
      }
      if( desc == null ) {
        if( z.mem.startsWith( u8, line, "Comment=" ) )
          desc = try alloc.dupe( u8, line[8..i-s] );
      }

      s = i + 1;
    }

    i += 1;
  }

  errdefer {
    if( name != null ) alloc.free( name.? );
    if( exec != null ) alloc.free( exec.? );
    if( desc != null ) alloc.free( desc.? );
  }

  if( name == null or exec == null or name.?.len == 0 or exec.?.len == 0 )
    return error.InvalidEntry;
  if( desc == null )
    desc = "";

  return XdgEntry {
     .name = name.?,
     .exec = exec.?,
     .desc = desc.?,
     .path = try alloc.dupe( u8, path )
  };
}

pub fn parseXDGEntries( entries: ArrayList( FsEntry ) ) !ArrayList( XdgEntry ) {
  var list = ArrayList( XdgEntry ).init( alloc );
  for( entries.items ) |entry| {
    if( entry.is_dir )
      continue;

    var handle = try z.fs.openFileAbsolute( entry.path, .{} );
    defer handle.close();

    var reader = handle.reader();
    const buf = try reader.readAllAlloc(alloc, 999999);
    defer alloc.free( buf );

    const xdg = parseXDGEntry( buf, entry.path ) catch continue;

    try list.append( xdg );
  }

  return list;
}

pub fn main() !void {
  var all_entries = ArrayList( XdgEntry ).init( alloc );
  for( paths ) |path| {
    var line = path;
    var free_path = false;

    const idx = z.mem.indexOf( u8, path, "~" );
    if( idx ) |i| {
      const home = try folders.getPath( alloc, .home );
      if( home == null )
        return error.NoHome;

      line = try allocprint( alloc, "{s}{s}", .{ home.?, line[i+1..] } );
      alloc.free( home.? );
      free_path = true;
    }
    defer { if( free_path ) alloc.free( line ); }

    const entries = try openDir( line );
    defer {
      for( entries.items ) |e|
        e.deinit();
      entries.deinit();
    }

    const list = try parseXDGEntries( entries );
    try all_entries.appendSlice( list.items );
    list.deinit();
  }

  for( all_entries.items ) |e| {
    if( e.desc.len > 0 ) {
      try z.io.getStdOut().writer().print( "{s} - {s}  |  {s}\n", .{ e.name, e.desc, e.path } );
    } else
      try z.io.getStdOut().writer().print( "{s}  |  {s}\n", .{ e.name, e.path } );

    e.deinit();
  }
  all_entries.deinit();

  _ = gpa.deinit();
}

