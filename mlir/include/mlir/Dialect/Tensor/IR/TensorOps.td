//===- TensorOps.td - Tensor op definitions ----------------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef TENSOR_OPS
#define TENSOR_OPS

include "mlir/Dialect/Tensor/IR/TensorBase.td"
include "mlir/Interfaces/ControlFlowInterfaces.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

class Tensor_Op<string mnemonic, list<OpTrait> traits = []>
    : Op<Tensor_Dialect, mnemonic, traits> {
  let printer = [{ return ::print(p, *this); }];
  let verifier = [{ return ::verify(*this); }];
  let parser = [{ return ::parse$cppClass(parser, result); }];
}

//===----------------------------------------------------------------------===//
// CastOp
//===----------------------------------------------------------------------===//

def Tensor_CastOp : Tensor_Op<"cast", [NoSideEffect]> {
  let summary = "tensor cast operation";
  let description = [{
    Convert a tensor from one type to an equivalent type without changing any
    data elements. The source and destination types must both be tensor types
    with the same element type. If both are ranked, then the rank should be the
    same and static dimensions should match. The operation is invalid if
    converting to a mismatching constant dimension.

    Example:

    ```mlir
    // Convert from unknown rank to rank 2 with unknown dimension sizes.
    %2 = tensor.cast %1 : tensor<*xf32> to tensor<?x?xf32>

    // Convert to a type with more known dimensions.
    %3 = tensor.cast %2 : tensor<?x?xf32> to tensor<4x?xf32>

    // Discard static dimension and rank information.
    %4 = tensor.cast %3 : tensor<4x?xf32> to tensor<?x?xf32>
    %5 = tensor.cast %4 : tensor<?x?xf32> to tensor<*xf32>
    ```
  }];

  let arguments = (ins AnyTensor:$source);
  let results = (outs AnyTensor:$dest);
  let assemblyFormat = "$source attr-dict `:` type($source) `to` type($dest)";
  let verifier = "return impl::verifyCastOp(*this, areCastCompatible);";

  let extraClassDeclaration = [{
    /// Return true if `a` and `b` are valid operand and result pairs for
    /// the operation.
    static bool areCastCompatible(Type a, Type b);

    /// The result of a tensor.cast is always a tensor.
    TensorType getType() { return getResult().getType().cast<TensorType>(); }
  }];

  let hasFolder = 1;
  let hasCanonicalizer = 1;
}

//===----------------------------------------------------------------------===//
// ExtractOp
//===----------------------------------------------------------------------===//

def Tensor_ExtractOp : Tensor_Op<"extract",
    [NoSideEffect,
     TypesMatchWith<"result type matches element type of tensor",
                    "tensor", "result",
                    "$_self.cast<ShapedType>().getElementType()">]> {
  let summary = "element extraction operation";
  let description = [{
    The `tensor.extract` op reads a tensor and returns one
    element from it specified by an index list. The output of the op is a
    new value with the same type as the elements of the tensor. The
    arity of indices must match the rank of the accessed value (i.e., if a
    tensor is of rank 3, then 3 indices are required for the extract. The
    indices should all be of `index` type.

    Example:

    ```mlir
    %4 = tensor.extract %t[%1, %2] : tensor<4x4xi32>
    %5 = tensor.extract %rt[%1, %2] : tensor<?x?xi32>
    %6 = tensor.extract %ut[%1, %2] : tensor<*xi32>
    ```
  }];

  let arguments = (ins AnyTensor:$tensor, Variadic<Index>:$indices);
  let results = (outs AnyType:$result);
  let assemblyFormat = "$tensor `[` $indices `]` attr-dict `:` type($tensor)";

  let builders = [
    OpBuilderDAG<(ins "Value":$tensor, CArg<"ValueRange", "{}">:$indices), [{
      auto resType = tensor.getType().cast<ShapedType>().getElementType();
      build($_builder, $_state, resType, tensor, indices);
    }]>];

  let hasFolder = 1;
}

//===----------------------------------------------------------------------===//
// FromElementsOp
//===----------------------------------------------------------------------===//

def Tensor_FromElementsOp : Tensor_Op<"from_elements", [
    NoSideEffect,
    TypesMatchWith<"operand types match result element type",
                   "result", "elements", "SmallVector<Type, 2>("
                   "$_self.cast<ShapedType>().getDimSize(0), "
                   "$_self.cast<ShapedType>().getElementType())">
  ]> {
  string summary = "tensor from elements operation.";
  string description = [{
    Create a 1D tensor from a range of same-type arguments.

    Example:

    ```mlir
    tensor.from_elements(i_1, ..., i_N) :  tensor<Nxindex>
    ```
  }];

  let arguments = (ins Variadic<AnyType>:$elements);
  let results = (outs 1DTensorOf<[AnyType]>:$result);

  let assemblyFormat = "$elements attr-dict `:` type($result)";

  // This op is fully verified by its traits.
  let verifier = ?;

  let skipDefaultBuilders = 1;
  let builders = [
    OpBuilderDAG<(ins "Type":$elementType, "ValueRange":$elements)>,
    // Special case builder for when `elements` has size >=1.
    OpBuilderDAG<(ins "ValueRange":$elements)>
  ];

  let hasCanonicalizer = 1;
}

//===----------------------------------------------------------------------===//
// GenerateOp
//===----------------------------------------------------------------------===//

def Tensor_GenerateOp : Tensor_Op<"generate",
    [RecursiveSideEffects,
     SingleBlockImplicitTerminator<"mlir::tensor::YieldOp">]> {
  string summary = "Creates a dynamically sized tensor from elements";
  string description = [{
    This operation creates a dynamically sized tensor with elements of any type.
    It expects one index operand per dynamic extent of the result tensor.

    The body region defines the tensor's elements. It takes index operands as
    its region arguments that span the index space. The element at the given
    position is yielded with the `yield` operation (see `YieldOp`). There is
    no defined ordering to the invocations of the body. It is conceptually
    a "parallel map" operation.

    Example:

    ```mlir
      %tnsr = tensor.generate %m, %n {
      ^bb0(%i : index, %j : index, %k : index):
        ...
        yield %elem : f32
      } : tensor<?x3x?f32>
    ```
  }];

  let arguments = (ins Variadic<Index>:$dynamicExtents);
  let results = (outs AnyRankedTensor:$result);
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = "$dynamicExtents $body attr-dict `:` type($result)";

  let builders = [
    // Build op and populate its body per callback function.
    OpBuilderDAG<(ins "Type":$resultTy, "ValueRange":$dynamicExtents,
      "function_ref<void(OpBuilder &, Location, ValueRange)>")>,
  ];

  let hasCanonicalizer = 1;
}

//===----------------------------------------------------------------------===//
// YieldOp
//===----------------------------------------------------------------------===//

def Tensor_YieldOp : Tensor_Op<"yield",
    [NoSideEffect, ReturnLike, Terminator,
     HasParent<"::mlir::tensor::GenerateOp">]> {
  let summary = "Yield a value from a region";
  let description = [{
     This operation is used to yield a single value from a within a region. It
     is used to create dynamically sized tensors
     (see `tensor.generate` op).
  }];

  let arguments = (ins AnyType:$value);
  let assemblyFormat = "$value attr-dict `:` type($value)";
  // Dummy builder to appease code in templated ensureTerminator that
  // GenerateOp's auto-generated parser calls.
  let builders = [OpBuilderDAG<(ins), [{ /* nothing to do */ }]>];
  let verifier = ?;
}

#endif // TENSOR_OPS
