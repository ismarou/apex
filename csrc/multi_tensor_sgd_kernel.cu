#include <ATen/ATen.h>
#include <ATen/AccumulateType.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/Exceptions.h>
#include "multi_tensor_apply.cuh"

#include <assert.h>
#include <cuda_runtime.h>

#define BLOCK_SIZE 512
#define ILP 4

/**
 * Perform fused SGD on multiple buffers
 * tl[0] : gradients
 * tl[1] : weights
 * tl[2] : momentum buffers
 * wd : weight_decay (scalar)
 * momentum : momentum (scalar)
 * dampening : momentum dampening (scalar)
 * lr : learning rate (scalar)
 * nesterov : enable nesterov (bool)
 * first run : necessary for proper momentum handling & init
 **/
template<typename T>
struct SGDFunctor
{
   __device__ __forceinline__ void operator()(
    int chunk_size,
    volatile int* noop_gmem,
    TensorList<3>& tl,
    float wd,
    float momentum,
    float dampening,
    float lr,
    bool nesterov,
    bool first_run)
  {
    __shared__ int noop_smem;

    if(threadIdx.x == 0)
      noop_smem = *noop_gmem;
    __syncthreads();
    if(noop_smem == 1)
      return;

    int tensor_loc = tl.block_to_tensor[blockIdx.x];
    int chunk_idx = tl.block_to_chunk[blockIdx.x];
    int n = tl.sizes[tensor_loc];

    T* grad_in = (T*)tl.addresses[0][tensor_loc];
    grad_in += chunk_idx*chunk_size;
   
    T* weight_in = (T*)tl.addresses[1][tensor_loc];
    weight_in += chunk_idx*chunk_size;

    T* mom_in = (T*)tl.addresses[2][tensor_loc];
    mom_in += chunk_idx*chunk_size;

    n -= chunk_idx*chunk_size;

    // Non-divergent exit condition for the __syncthreads
    float incoming_grads[ILP];
    float incoming_weights[ILP];
    float incoming_moms[ILP];
    for(int i_start = 0;
        i_start < n && i_start < chunk_size;
        i_start += blockDim.x*ILP)
    {
      #pragma unroll
      for(int ii = 0; ii < ILP; ii++)
      {
        incoming_grads[ii] = 0;
        incoming_weights[ii] = 0;
        incoming_moms[ii] = 0;
        int i = i_start + threadIdx.x + ii*blockDim.x;
        if(i < n && i < chunk_size)
          incoming_grads[ii] = static_cast<float>(grad_in[i]);
          incoming_weights[ii] = static_cast<float>(weight_in[i]);
          incoming_moms[ii] = static_cast<float>(mom_in[i]);
      }

      // note for clarification to future michael:
      // From a pure memory dependency perspective, there's likely no point unrolling
      // the write loop, since writes just fire off once their LDGs arrive.
      // Put another way, the STGs are dependent on the LDGs, but not on each other.
      // There is still compute ILP benefit from unrolling the loop though.
      #pragma unroll
      for(int ii = 0; ii < ILP; ii++)
      {
        int i = i_start + threadIdx.x + ii*blockDim.x;
        if(i < n && i < chunk_size) {
          // apply weight decay
          if (wd != 0.f) {
            incoming_grads[ii] += wd * incoming_weights[ii];
          }
          if (momentum != 0.f) {
            if (!first_run) {
              incoming_moms[ii] = incoming_moms[ii] * momentum + (1.f - dampening) * incoming_grads[ii];
            }

            if (nesterov) {
              incoming_grads[ii] += momentum * incoming_moms[ii];
            }
          }

          // adjust the weight and write out
          weight_in[i] += (-lr * incoming_grads[ii]);

          // also write out the new momentum
          if (momentum != 0.f) {
            mom_in[i] = incoming_moms[ii];
          }
        }
      }

      // *noop_gmem = 1 is NOT guaranteed to be seen immediately by thread 0.  I wonder if
      // we can rig block-wide and grid-wide short-circuiting with only one syncthreads.
      // It's possible we can just lean on the cache (no smem or syncs) and still be fast.
      if(threadIdx.x == 0)
        noop_smem = *noop_gmem;
      __syncthreads();
      if(noop_smem == 1)
        break;
    }
  }
};

void multi_tensor_sgd_cuda(
  int chunk_size,
  at::Tensor noop_flag,
  std::vector<std::vector<at::Tensor>> tensor_lists,
  float wd,
  float momentum,
  float dampening,
  float lr,
  bool nesterov,
  bool first_run)
{
  multi_tensor_apply<3>(
      BLOCK_SIZE,
      chunk_size,
      noop_flag,
      tensor_lists,
      SGDFunctor<float>(),
      wd,
      momentum,
      dampening,
      lr,
      nesterov,
      first_run);

  AT_CUDA_CHECK(cudaGetLastError());

  // AT_CUDA_CHECK(cudaDeviceSynchronize());
}
