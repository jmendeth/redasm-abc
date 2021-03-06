/***************************************************************************
 * Copyright 2014, 2016 Alba Mendez                                      *
 * This file is part of redasm-abc.                                        *
 *                                                                         *
 * redasm-abc is free software: you can redistribute it and/or modify      *
 * it under the terms of the GNU General Public License as published by    *
 * the Free Software Foundation, either version 3 of the License, or       *
 * (at your option) any later version.                                     *
 *                                                                         *
 * redasm-abc is distributed in the hope that it will be useful,           *
 * but WITHOUT ANY WARRANTY; without even the implied warranty of          *
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           *
 * GNU General Public License for more details.                            *
 *                                                                         *
 * You should have received a copy of the GNU General Public License       *
 * along with redasm-abc.  If not, see <http://www.gnu.org/licenses/>.     *
 ***************************************************************************/

module redasm;

import std.regex;
import std.file;
import std.path;
import std.stdio;
import std.datetime;
import std.conv;
import std.array;

import abcfile;
import asprogram;
import assembler;
import disassembler;
import swffile;

//FIXME: option parsing
//FIXME: catch exceptions
//FIXME: stop at fs boundary
//FIXME: lock the tagfile

bool findRoot(ref string dir, ref string tagfile) {
  dir = absolutePath(dir);
  while (true) {
    if (exists(tagfile) && isFile(tagfile)) return true;
    if (dir.length == 1) return false;
    dir = dirName(dir);
    tagfile = buildPath(dir, baseName(tagfile));
  }
}

bool canCreateRoot(string root) {
  auto files = array(dirEntries(root, SpanMode.shallow));
  if (files.length != 1) return false;
  return matchFirst(files[0].name, r"\.swf$").length() == 1;
}

int main(string[] args) {
  string root = ".";
  string tagfile = ".redasm";
  SysTime mtime = SysTime(0);

  if (canCreateRoot(root)) {
    writeln("Creating a new disassembly.");
  } else if (findRoot(root, tagfile)) {
    writefln("Existing disassembly: %s", root);
    mtime = timeLastModified(tagfile);
  } else {
    writeln("Can't find an existing disassembly.");
    writeln("If you're trying to create one, please copy the .swf to an empty directory, and run redasm from there.");
    return 1;
  }

  // Find the SWF
  auto swfFiles = array(dirEntries(root, "*.swf", SpanMode.shallow));

  if (swfFiles.length < 1) {
    writeln("Error: no SWF file was found.");
    return 1;
  }
  if (swfFiles.length > 1) {
    writeln("Error: Too many SWF files found.");
    return 1;
  }

  // Prepare
  auto swfFile = swfFiles[0];
  if (mtime.stdTime) {
    if (timeLastModified(swfFile.name) != mtime) {
      writeln("Error: Modification times don't match, SWF (or tag file) was probably modified externally.");
      writefln("\nIf you want me to continue anyway, run:\n\n  touch %s %s\n", relativePath(swfFile), relativePath(tagfile));
      return 1;
    }
  } else {
    // First run, make backup
    copy(swfFile, swfFile ~ ".bak");
  }

  // Actually process the SWF
  scope swf = SWFFile.read(cast(ubyte[]) read(swfFile.name));
  processSWF(root, swf, mtime);
  std.file.write(swfFile.name, swf.write());

  // Store new time at the tagfile
  if (!mtime.stdTime)
    std.file.write(tagfile, "DON'T TOUCH OR MODIFY THIS FILE IN ANY WAY.\n");
  mtime = timeLastModified(swfFile.name);
  setTimes(tagfile, mtime, mtime);

  return 0;
}


void processSWF(string root, SWFFile swf, SysTime mtime) {
  int idx = 0;
  foreach (ref tag; swf.tags) {
    if (tag.type == TagType.DoABC || tag.type == TagType.DoABC2) {
      if (tag.type == TagType.DoABC2) {
        auto ptr = tag.data.ptr + 4; // skip flags
        while (*ptr++) {} // skip name

        auto data = tag.data[ptr-tag.data.ptr..$];
        auto header = tag.data[0..ptr-tag.data.ptr];
        processTag(root, data, idx, mtime);
        tag.data = header ~ data;
      } else {
        processTag(root, tag.data, idx, mtime);
      }
      tag.length = cast(uint) tag.data.length;
      idx++;
    }
  }

  if (idx == 0) {
    writeln("The SWF didn't contain ABC tags.");
  }
}

void processTag(string root, ref ubyte[] data, int idx, SysTime mtime) {
  string name = "block-" ~ to!string(idx);
  string dir = buildPath(root, name);
  if (mtime.stdTime) {
    if (exists(dir) && isDir(dir)) {

      if (modifiedAfter(dir, mtime)) {
        writefln("%s: Reassembling...", name);
        assemble(dir, name, data);
      } else {
        writefln("%s: Up to date.", name);
      }

    } else {
      writefln("%s: Directory not found, skipping.", name);
    }
  } else {
    writefln("%s: Disassembling...", name);
    scope abc = ABCFile.read(data);
    scope as = ASProgram.fromABC(abc);
    scope disassembler = new Disassembler(as, dir, name);
    disassembler.disassemble();

    // reassemble back to start clean
    assemble(dir, name, data);
  }
}

void assemble(string dir, string name, ref ubyte[] data) {
  scope as = new ASProgram;
  scope assembler = new Assembler(as);
  assembler.assemble(buildPath(dir, name ~ ".main.asasm"));
  scope abc = as.toABC();
  data = abc.write();
}


// UTILITIES

SysTime timeLastModified(in string file) {
  SysTime atime, mtime;
  getTimes(file, atime, mtime);
  return mtime;
}

bool modifiedAfter(string dir, SysTime mtime) {
  foreach(DirEntry e; dirEntries(dir, SpanMode.depth, false)) {
    if (e.timeLastModified > mtime) return true;
  }
  return false;
}
