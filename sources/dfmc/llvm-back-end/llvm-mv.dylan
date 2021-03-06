Module: dfmc-llvm-back-end
Copyright:    Original Code is Copyright (c) 1995-2004 Functional Objects, Inc.
              Additional code is Copyright 2009-2013 Gwydion Dylan Maintainers
              All rights reserved.
License:      See License.txt in this distribution for details.
Warranty:     Distributed WITHOUT WARRANTY OF ANY KIND

define abstract class <llvm-mv> (<object>)
end class;

// Multiple values represented as local SSA values
define class <llvm-local-mv> (<llvm-mv>)
  constant slot llvm-mv-fixed :: <sequence>,
    init-value: #[], init-keyword: fixed:;
  constant slot llvm-mv-rest :: false-or(<llvm-value>),
    init-value: #f, init-keyword: rest:;
end class;

// Extract a single value
define method op--mv-extract
    (back-end :: <llvm-back-end>, mv :: <llvm-local-mv>, index :: <integer>)
 => (value :: <llvm-value>);
  let fixed = mv.llvm-mv-fixed;
  if (index < fixed.size)
    fixed[index]
  elseif (mv.llvm-mv-rest)
    error("mv-extract beyond fixed with rest")
  else
    let module = back-end.llvm-builder-module;
    emit-reference(back-end, module, &false)
  end if
end method;

// Extract values beyond the given index in a rest vector
define method op--mv-extract-rest
    (back-end :: <llvm-back-end>, mv :: <llvm-local-mv>, index :: <integer>)
 => (value :: <llvm-value>);
  let module = back-end.llvm-builder-module;
  if (index = mv.llvm-mv-fixed.size)
    mv.llvm-mv-rest
      | emit-reference(back-end, module, dylan-value(#"%empty-vector"))
  elseif (~mv.llvm-mv-rest)
    // FIXME this can be simplified
    let rest-count = mv.llvm-mv-fixed.size - index;
    if (rest-count <= 0)
      emit-reference(back-end, module, dylan-value(#"%empty-vector"))
    else
      let rest-vector = op--allocate-vector(back-end, rest-count);
      for (i from index below mv.llvm-mv-fixed.size)
        call-primitive(back-end, primitive-vector-element-setter-descriptor,
                       mv.llvm-mv-fixed[i], rest-vector,
                       llvm-back-end-value-function(back-end, i - index));
      end for;
      rest-vector
    end if
  else
    error("op--mv-extract-rest is hard %= (%d, %=) [%d]",
          mv, mv.llvm-mv-fixed.size, mv.llvm-mv-rest.true?, index)
  end if
end method;

// Multiple values stored in the TEB MV area
define class <llvm-global-mv> (<llvm-mv>)
  constant slot llvm-mv-struct :: <llvm-value>,
    required-init-keyword: struct:;
  constant slot llvm-mv-maximum :: <integer>,
    init-keyword: maximum:, init-value: $maximum-value-count;
end class;

define method op--mv-extract
    (back-end :: <llvm-back-end>, mv :: <llvm-global-mv>, index :: <integer>)
 => (value :: <llvm-value>);
  if (index = 0)
    ins--extractvalue(back-end, mv.llvm-mv-struct, 0)
  elseif (index < mv.llvm-mv-maximum)
    let ptr = op--teb-getelementptr(back-end, #"teb-mv-area", index);
    ins--load(back-end, ptr)
  else
    let module = back-end.llvm-builder-module;
    emit-reference(back-end, module, &false)
  end if
end method;

// Extract global values into a rest vector
define method op--mv-extract-rest
    (back-end :: <llvm-back-end>, mv :: <llvm-global-mv>, index :: <integer>)
 => (value :: <llvm-value>);
  let count = ins--extractvalue(back-end, mv.llvm-mv-struct, 1);
  let raw-integer-type
    = llvm-reference-type(back-end, dylan-value(#"<raw-integer>"));
  let rest-vector
    = call-primitive(back-end, primitive-mv-extract-rest-descriptor,
                     llvm-back-end-value-function(back-end, index),
                     ins--zext(back-end, count, raw-integer-type));
  if (index = 0)
    // Fill in the 0th value
    let primary = ins--extractvalue(back-end, mv.llvm-mv-struct, 0);
    call-primitive(back-end, primitive-vector-element-setter-descriptor,
                   primary, rest-vector,
                   llvm-back-end-value-function(back-end, 0));
  end if;
  rest-vector
end method;

define side-effect-free stateful indefinite-extent auxiliary &runtime-primitive-descriptor primitive-mv-extract-rest
    (index :: <raw-integer>, count :: <raw-integer>)
 => (box :: <simple-object-vector>);
  let module = be.llvm-builder-module;
  let word-size = back-end-word-size(be);
  let raw-integer-type = llvm-reference-type(be, dylan-value(#"<raw-integer>"));

  // Basic blocks
  let entry-bb = be.llvm-builder-basic-block;
  let vector-bb = make(<llvm-basic-block>);
  let loop-head-bb = make(<llvm-basic-block>);
  let loop-tail-bb = make(<llvm-basic-block>);
  let return-bb = make(<llvm-basic-block>);

  let rest-count = ins--sub(be, count, index);
  let empty?-cmp = ins--icmp-sle(be, rest-count, 0);
  ins--br(be, empty?-cmp, return-bb, vector-bb);

  // Allocate a <simple-object-vector>
  ins--block(be, vector-bb);
  let rest-vector = op--allocate-vector(be, rest-count);

  // Store values from the global area into it
  let mv-base = op--teb-getelementptr(be, #"teb-mv-area", index);

  // If index is 0, skip over the first element (the caller will fill it in)
  let index-zero?-cmp = ins--icmp-eq(be, index, 0);
  let start = ins--select(be, index-zero?-cmp, 1, 0);
  ins--br(be, loop-head-bb);

  ins--block(be, loop-head-bb);
  let i-placeholder
    = make(<llvm-symbolic-value>, type: raw-integer-type, name: "i");
  let i = ins--phi*(be, start, vector-bb, i-placeholder, loop-tail-bb);
  let cmp = ins--icmp-ult(be, i, rest-count);
  ins--br(be, cmp, loop-tail-bb, return-bb);

  // Copy the value from the MV area to the vector
  ins--block(be, loop-tail-bb);
  let mv-ptr = ins--gep(be, mv-base, i);
  let value = ins--load(be, mv-ptr, alignment: word-size);
  call-primitive(be, primitive-vector-element-setter-descriptor,
                 value, rest-vector, i);

  let next-i = ins--add(be, i, 1);
  i-placeholder.llvm-placeholder-value-forward := next-i;
  ins--br(be, loop-head-bb);

  // Return
  ins--block(be, return-bb);
  let empty-vector
    = emit-reference(be, module, dylan-value(#"%empty-vector"));
  ins--phi*(be,
            empty-vector, entry-bb,
            rest-vector, loop-head-bb);
end;

// Emit the construction of an MV struct
define method op--global-mv-struct
    (back-end :: <llvm-back-end>,
     primary :: <llvm-value>,
     count :: <llvm-value>)
 => (struct :: <llvm-value>);
  let undef-struct
    = make(<llvm-undef-constant>,
           type: llvm-reference-type(back-end, back-end.%mv-struct-type));
  llvm-constrain-type(primary.llvm-value-type, $llvm-object-pointer-type);
  let value-struct
    = ins--insertvalue(back-end, undef-struct, primary, 0);
  llvm-constrain-type(count.llvm-value-type, $llvm-i8-type);
  ins--insertvalue(back-end, value-struct, count, 1)
end method;

// Save a multiple-value temporary to be restored later
define method op--protect-temporary
    (back-end :: <llvm-back-end>, temp, value)
 => (spill :: <llvm-value>);
  // Nothing to do
  emit-reference(back-end, back-end.llvm-builder-module, &false)
end method;

define method op--protect-temporary
    (back-end :: <llvm-back-end>, temp :: <multiple-value-temporary>,
     mv :: <llvm-global-mv>)
 => (spill :: <llvm-value>);
  if (temp.required-values > 1 | temp.rest-values?)
    let copy-bb = make(<llvm-basic-block>);
    let continue-bb = make(<llvm-basic-block>);

    // Allocate a local spill area
    let maximum-count
      = if (temp.rest-values?)
          mv.llvm-mv-maximum - 1
        else
          temp.required-values - 1
        end;
    let word-size = back-end-word-size(back-end);
    let spill = ins--alloca(back-end, $llvm-object-pointer-type, maximum-count);
    let spill-cast = ins--bitcast(back-end, spill, $llvm-i8*-type);

    // Determine how many values are in the TEB MV area
    let count = ins--extractvalue(back-end, mv.llvm-mv-struct, 1);
    let count-ext = ins--zext(back-end, count, back-end.%type-table["iWord"]);
    let mv-area-count = ins--sub(back-end, count-ext, 1);
    let cmp = ins--icmp-sgt(back-end, mv-area-count, 0);
    ins--br(back-end, cmp, copy-bb, continue-bb);

    // Copy MV area values
    ins--block(back-end, copy-bb);
    let ptr = op--teb-getelementptr(back-end, #"teb-mv-area", 1);
    let ptr-cast = ins--bitcast(back-end, ptr, $llvm-i8*-type);
    let byte-count = ins--mul(back-end, mv-area-count, word-size);
    ins--call-intrinsic(back-end, "llvm.memcpy",
                        vector(spill-cast, ptr-cast, byte-count,
                               i32(word-size), $llvm-false));
    ins--br(back-end, continue-bb);

    ins--block(back-end, continue-bb);
    spill
  else
    emit-reference(back-end, back-end.llvm-builder-module, &false)
  end if;
end method;

define method op--restore-temporary
    (back-end :: <llvm-back-end>, temp, value, spill :: <llvm-value>)
 => ();
  // Nothing to do
end method;

define method op--restore-temporary
    (back-end :: <llvm-back-end>, temp :: <multiple-value-temporary>,
     mv :: <llvm-global-mv>, spill :: <llvm-value>)
 => ();
  if (temp.required-values > 1 | temp.rest-values?)
    let copy-bb = make(<llvm-basic-block>);
    let continue-bb = make(<llvm-basic-block>);

    // Determine how many values need to be restored to the TEB MV area
    let count = ins--extractvalue(back-end, mv.llvm-mv-struct, 1);
    let count-ext = ins--zext(back-end, count, back-end.%type-table["iWord"]);
    let mv-area-count = ins--sub(back-end, count-ext, 1);
    let cmp = ins--icmp-sgt(back-end, mv-area-count, 0);
    ins--br(back-end, cmp, copy-bb, continue-bb);

    // Copy spill values to the MV area
    ins--block(back-end, copy-bb);
    let word-size = back-end-word-size(back-end);
    let spill-cast = ins--bitcast(back-end, spill, $llvm-i8*-type);
    let ptr = op--teb-getelementptr(back-end, #"teb-mv-area", 1);
    let ptr-cast = ins--bitcast(back-end, ptr, $llvm-i8*-type);
    let byte-count = ins--mul(back-end, mv-area-count, word-size);
    ins--call-intrinsic(back-end, "llvm.memcpy",
                        vector(ptr-cast, spill-cast, byte-count,
                               i32(word-size), $llvm-false));
    ins--br(back-end, continue-bb);

    ins--block(back-end, continue-bb);
  end if;
end method;
