#include <ATen/ATen.h>
#include <ATen/AccumulateType.h>
#include <ATen/native/Pool.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>
#include <ATen/cuda/detail/TensorInfo.cuh>
#include <ATen/cuda/detail/IndexUtils.cuh>
#include <ATen/cuda/detail/KernelUtils.h>
#include <THC/THCNumerics.cuh>
#include <c10/macros/Macros.h>


namespace at {
namespace native {
namespace {

__device__ inline int min(int a, int b) {
  return a <= b ? a : b;
}

// kernels borrowed from Caffe
template <typename scalar_t, typename accscalar_t>
__global__ void MaxPoolForward(const int nthreads, const scalar_t* bottom_data,
    const int num, const int depth, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h,
    const int stride_w, const int pad_h, const int pad_w,
    const int dilation_h, const int dilation_w,
    const int in_stride_c, const int in_stride_h, const int in_stride_w,
    scalar_t* top_data, int64_t* top_mask) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % depth;
    int n = index / pooled_width / pooled_height / depth;
    int hstart = ph * stride_h - pad_h;
    int wstart = pw * stride_w - pad_w;
    int hend = min(hstart + (kernel_h - 1) * dilation_h + 1, height);
    int wend = min(wstart + (kernel_w - 1) * dilation_w + 1, width);
    while(hstart < 0)
      hstart += dilation_h;
    while(wstart < 0)
      wstart += dilation_w;
    accscalar_t maxval = at::numeric_limits<accscalar_t>::lower_bound(); // -Infinity
    int maxidx = hstart * in_stride_h + wstart * in_stride_w;
    bottom_data += (n * depth * height * width + c * in_stride_c);
    for (int h = hstart; h < hend; h += dilation_h) {
      for (int w = wstart; w < wend; w += dilation_w) {
        scalar_t val = bottom_data[h * in_stride_h + w * in_stride_w];
        if ((ScalarConvert<scalar_t, accscalar_t>::to(val) > maxval) || THCNumerics<scalar_t>::isnan(val)) {
          maxidx = h * in_stride_h + w * in_stride_w;
          maxval = ScalarConvert<scalar_t, accscalar_t>::to(val);
        }
      }
    }
    top_data[index] = ScalarConvert<scalar_t, accscalar_t>::to(maxval);
    top_mask[index] = maxidx;
  }
}

static const int BACKWARD_THREADS = 256;

template <typename scalar_t, typename accscalar_t>
#if defined (__HIP_PLATFORM_HCC__)
C10_LAUNCH_BOUNDS_2(BACKWARD_THREADS, 4)
#else
C10_LAUNCH_BOUNDS_2(BACKWARD_THREADS, 8)
#endif
__global__ void MaxPoolBackward(const int nthreads, const scalar_t* top_diff,
    const int64_t* top_mask, const int num, const int depth,
    const int height, const int width, const int pooled_height,
    const int pooled_width, const int kernel_h, const int kernel_w,
    const int stride_h, const int stride_w, const int pad_h, const int pad_w,
    const int dilation_h, const int dilation_w,
    const int out_stride_c, const int out_stride_h, const int out_stride_w,
    const int in_stride_c, const int in_stride_h, const int in_stride_w,
    scalar_t* bottom_diff) {
    CUDA_KERNEL_LOOP(index, height*width) {
    int h = index/width;
    int w = index - h * width;
//get some templating performance benefits without actually templating
    int phstart, phend, pwstart, pwend;
    if (stride_h == 1) {
       phstart =
        (h + pad_h < ((kernel_h - 1) * dilation_h + 1)) ? 0 : (h + pad_h - ((kernel_h - 1) * dilation_h + 1))  + 1;
       phend = min((h + pad_h)  + 1, pooled_height);
    } else if (stride_h == 2) {
       phstart =
        (h + pad_h < ((kernel_h - 1) * dilation_h + 1)) ? 0 : (h + pad_h - ((kernel_h - 1) * dilation_h + 1)) / 2  + 1;
       phend = min((h + pad_h) / 2  + 1, pooled_height);
    } else {
       phstart =
        (h + pad_h < ((kernel_h - 1) * dilation_h + 1)) ? 0 : (h + pad_h - ((kernel_h - 1) * dilation_h + 1)) / stride_h  + 1;
       phend = min((h + pad_h) / stride_h  + 1, pooled_height);
    }
    if (stride_w == 1) {
        pwstart =
        (w + pad_w < ((kernel_w - 1) * dilation_w + 1)) ? 0 : (w + pad_w - ((kernel_w - 1) * dilation_w + 1)) + 1;
        pwend = min((w + pad_w) + 1, pooled_width);
    } else if (stride_w == 2) {
        pwstart =
        (w + pad_w < ((kernel_w - 1) * dilation_w + 1)) ? 0 : (w + pad_w - ((kernel_w - 1) * dilation_w + 1)) / 2 + 1;
        pwend = min((w + pad_w) / 2 + 1, pooled_width);
    } else {
        pwstart =
        (w + pad_w < ((kernel_w - 1) * dilation_w + 1)) ? 0 : (w + pad_w - ((kernel_w - 1) * dilation_w + 1)) / stride_w + 1;
        pwend = min((w + pad_w) / stride_w + 1, pooled_width);
    }
    for (int n = blockIdx.y; n < num; n += gridDim.y)
       for (int c = blockIdx.z; c < depth; c+= gridDim.z) {

        accscalar_t gradient = accscalar_t(0);
        int offset = (n * depth * pooled_height * pooled_width + c * out_stride_c);
        top_diff += offset;
        top_mask += offset;
//get some templating performance benefits without actually templating
        if ((phstart + 1 != phend) || (pwstart + 1 != pwend)) {
        for (int ph = phstart; ph < phend; ++ph) {
          for (int pw = pwstart; pw < pwend; ++pw) {
            if (top_mask[ph * out_stride_h + pw * out_stride_w] == index) {
              gradient += ScalarConvert<scalar_t, accscalar_t>::to(top_diff[ph * out_stride_h + pw * out_stride_w]);
            }
          }
        }
        } else {
            if (top_mask[phstart * out_stride_h + pwstart * out_stride_w] == index) {
              gradient += ScalarConvert<scalar_t, accscalar_t>::to(top_diff[phstart * out_stride_h + pwstart * out_stride_w]);
            }
        }
        bottom_diff[n*depth*height*width + c * in_stride_c + h * in_stride_h + w * in_stride_w] = ScalarConvert<accscalar_t, scalar_t>::to(gradient);
      }
  }
}

void max_pool2d_with_indices_out_cuda_template(
           Tensor& output,
           Tensor& indices,
           const Tensor& input_,
           IntArrayRef kernel_size,
           IntArrayRef stride,
           IntArrayRef padding,
           IntArrayRef dilation,
           bool ceil_mode)
{
  TensorArg output_arg{ output, "output", 1 };
  TensorArg indices_arg{ indices, "indices", 2 };
  TensorArg input_arg{ input_, "input_", 3 };

  checkAllSameGPU("max_pool2d_with_indices_out_cuda",
                  {output_arg, indices_arg, input_arg});

  // #20866, #22032: Guarantee this for the official C++ API?
  TORCH_CHECK((kernel_size.size() == 1 || kernel_size.size() == 2) &&
              (stride.empty() || stride.size() == 2) &&
              (padding.size() == 1 || padding.size() == 2) &&
              (dilation.size() == 1 || dilation.size() == 2),
    "max_pool2d_with_indices: internal error: all IntArrayRef sizes must be 2");

  TORCH_CHECK((input_.ndimension() == 3 || input_.ndimension() == 4),
    "non-empty 3D or 4D (batch mode) tensor expected for input");

  const int kH = safe_downcast<int, int64_t>(kernel_size[0]);
  const int kW = kernel_size.size() == 1 ? kH : safe_downcast<int, int64_t>(kernel_size[1]);

  const int dH = stride.empty() ? kH : safe_downcast<int, int64_t>(stride[0]);
  const int dW = stride.empty() ? kW : safe_downcast<int, int64_t>(stride[1]);

  const int padH = safe_downcast<int, int64_t>(padding[0]);
  const int padW = padding.size() == 1 ? padH : safe_downcast<int, int64_t>(padding[1]);

  const int dilationH = safe_downcast<int, int64_t>(dilation[0]);
  const int dilationW = dilation.size() == 1 ? dilationH : safe_downcast<int, int64_t>(dilation[1]);

  const auto memory_format = input_.suggest_memory_format();

  const int64_t nbatch = input_.ndimension() == 4 ? input_.size(-4) : 1;
  const int64_t size3 = input_.size(-3); // nInputPlane or inputHeight
  const int64_t size2 = input_.size(-2); // inputHeight or inputWidth
  const int64_t size1 = input_.size(-1); // inputWidth or nInputPlane

  int64_t stride3;
  int64_t stride2;
  int64_t stride1;
  int64_t inputWidth;
  int64_t inputHeight;
  if (memory_format == MemoryFormat::ChannelsLast)  {
    stride1 = 1; // channels stride
    stride2 = size1; // width stride = channels size
    stride3 = size2 * size1; // height stride = channels * width
    inputWidth = size2;
    inputHeight = size3;
  } else {
    stride1 = size2 * size1; // channel stride = height * width
    stride2 = size1; // height stride = width
    stride3 = 1; // width stride
    inputWidth = size1;
    inputHeight = size2;
  }

  const int64_t outputWidth = pooling_output_shape<int64_t>(inputWidth, kW, padW, dW, dilationW, ceil_mode);
  const int64_t outputHeight = pooling_output_shape<int64_t>(inputHeight, kH, padH, dH, dilationH, ceil_mode);

  pool2d_shape_check(
    input_,
    kH, kW, dH, dW, padH, padW, dilationH, dilationW,
    size3,
    size2, size1,
    outputHeight, outputWidth);

  Tensor input = input_.contiguous(memory_format);

  output.resize_({nbatch, size3, size2, size1});
  indices.resize_({nbatch, size3, size2, size1});

  const int count = safe_downcast<int, int64_t>(output.numel());
  const int num_threads = std::min(at::cuda::getCurrentDeviceProperties()->maxThreadsPerBlock,
                                   BACKWARD_THREADS);

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(input.scalar_type(),
    "max_pool2d_with_indices_out_cuda_frame",
    [&] {
      using accscalar_t = acc_type<scalar_t, true>;

      scalar_t *output_data = output.data<scalar_t>();
      scalar_t *input_data = input.data<scalar_t>();
      int64_t *indices_data = indices.data<int64_t>();

      MaxPoolForward<scalar_t, scalar_t>
        <<<cuda::ATenCeilDiv(count, num_threads), num_threads, 0, at::cuda::getCurrentCUDAStream()>>>(
          count, input_data,
          nbatch, size3, size2, size1, outputHeight, outputWidth,
          kH, kW, dH, dW, padH, padW, dilationH, dilationW,
          stride3, stride2, stride1,
          output_data, indices_data); }
  );

  TORCH_CHECK(cudaGetLastError() == cudaSuccess,
     "max_pool2d_with_indices_out_cuda_frame failed with error code ",
     cudaGetLastError());

  if(input.ndimension() == 3) {
    output.resize_({size3, size2, size1});
  }
}

void max_pool2d_with_indices_backward_out_cuda_template(
           Tensor& gradInput,
           const Tensor& gradOutput_,
           const Tensor& input_,
           const Tensor& indices,
           IntArrayRef kernel_size,
           IntArrayRef stride,
           IntArrayRef padding,
           IntArrayRef dilation,
           bool ceil_mode)
{
  TensorArg gradInput_arg{ gradInput, "gradInput", 1 };
  TensorArg gradOutput_arg{ gradOutput_, "gradOutput_", 2 };
  TensorArg input_arg{ input_, "input_", 3 };
  TensorArg indices_arg{ indices, "indices", 4 };

  checkAllSameGPU("max_pool2d_with_indices_out_cuda",
                  {gradInput_arg, gradOutput_arg, input_arg, indices_arg});

  // #20866, #22032: Guarantee this for the official C++ API?
  TORCH_CHECK((kernel_size.size() == 1 || kernel_size.size() == 2) &&
              (stride.empty() || stride.size() == 2) &&
              (padding.size() == 1 || padding.size() == 2) &&
              (dilation.size() == 1 || dilation.size() == 2),
    "max_pool2d_with_indices: internal error: all IntArrayRef sizes must be 2");

  TORCH_CHECK((input_.ndimension() == 3 || input_.ndimension() == 4),
    "non-empty 3D or 4D (batch mode) tensor expected for input");

  const int kH = safe_downcast<int, int64_t>(kernel_size[0]);
  const int kW = kernel_size.size() == 1 ? kH : safe_downcast<int, int64_t>(kernel_size[1]);

  const int dH = stride.empty() ? kH : safe_downcast<int, int64_t>(stride[0]);
  const int dW = stride.empty() ? kW : safe_downcast<int, int64_t>(stride[1]);

  const int padH = safe_downcast<int, int64_t>(padding[0]);
  const int padW = padding.size() == 1 ? padH : safe_downcast<int, int64_t>(padding[1]);

  const int dilationH = safe_downcast<int, int64_t>(dilation[0]);
  const int dilationW = dilation.size() == 1 ? dilationH : safe_downcast<int, int64_t>(dilation[1]);

  const auto memory_format = input_.suggest_memory_format();

  const Tensor input = input_.contiguous(memory_format);

  const int64_t nbatch = input_.ndimension() == 4 ? input_.size(-4) : 1;
  const int64_t size3 = input_.size(-3); // nInputPlane or inputHeight
  const int64_t size2 = input_.size(-2); // inputHeight or inputWidth
  const int64_t size1 = input_.size(-1); // inputWidth or nInputPlane

  int64_t i_stride3;
  int64_t i_stride2;
  int64_t i_stride1;
  int64_t outputHeight;
  int64_t outputWidth;
  int64_t o_stride3;
  int64_t o_stride2;
  int64_t o_stride1;
  if (memory_format == MemoryFormat::ChannelsLast)  {
    i_stride1 = 1; // channels stride
    i_stride2 = size1; // width stride = channels size
    i_stride3 = size2 * size1; // height stride = channels * width
    outputHeight = pooling_output_shape<int64_t>(size3, kH, padH, dH, dilationH, ceil_mode);
    outputWidth = pooling_output_shape<int64_t>(size2, kW, padW, dW, dilationW, ceil_mode);
    o_stride1 = 1;
    o_stride2 = outputWidth;
    o_stride3 = outputHeight * outputWidth;
  } else {
    i_stride1 = size2 * size1; // channel stride = height * width
    i_stride2 = size1; // height stride = width
    i_stride3 = 1; // width stride
    outputHeight = pooling_output_shape<int64_t>(size2, kH, padH, dH, dilationH, ceil_mode);
    outputWidth = pooling_output_shape<int64_t>(size1, kW, padW, dW, dilationW, ceil_mode);
    o_stride1 = outputHeight * outputWidth;
    o_stride2 = outputWidth;
    o_stride3 = 1;
  }

  max_pool2d_backward_shape_check(
    input_,
    gradOutput_,
    indices,
    nbatch,
    kH, kW, dH, dW, padH, padW, dilationH, dilationW,
    size3,
    size2, size1,
    outputHeight, outputWidth,
    /*cuda=*/ true);

  const Tensor gradOutput = gradOutput_.contiguous(memory_format);
  gradInput.resize_as_(input);

  int64_t count = input.numel();
  dim3 grid;
  int imgcount = size2 * size1;
  const int blocks = (imgcount + BACKWARD_THREADS - 1) / BACKWARD_THREADS;
  grid.x = blocks;
  grid.y = nbatch;
  grid.z = size3;
  uint64_t maxGridY = at::cuda::getCurrentDeviceProperties()->maxGridSize[1];
  uint64_t maxGridZ = at::cuda::getCurrentDeviceProperties()->maxGridSize[2];
  if (maxGridY < grid.y) grid.y = maxGridY;
  if (maxGridZ < grid.z) grid.z = maxGridZ;

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(input.scalar_type(),
    "max_pool2d_with_indices_out_cuda_frame",
    [&] {
      using accscalar_t = acc_type<scalar_t, true>;

      scalar_t *gradOutput_data = gradOutput.data<scalar_t>();
      scalar_t *gradInput_data = gradInput.data<scalar_t>();
      int64_t *indices_data = indices.data<int64_t>();

      MaxPoolBackward<scalar_t, accscalar_t>
        <<<grid, BACKWARD_THREADS, 0, at::cuda::getCurrentCUDAStream()>>>(
          count,
          gradOutput_data,
          indices_data,
          nbatch,
          size3, size2, size1, outputHeight, outputWidth,
          kH, kW, dH, dW, padH, padW, dilationH, dilationW,
          o_stride3, o_stride2, o_stride1,
          i_stride3, i_stride2, i_stride1,
          gradInput_data);
    }
  );

  TORCH_CHECK(cudaGetLastError() == cudaSuccess,
    "fractional_max_pool2d_backward_out_cuda failed with error code ",
    cudaGetLastError());
}

} // namespace

std::tuple<Tensor&, Tensor&> max_pool2d_with_indices_out_cuda(
  Tensor& output,
  Tensor& indices,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  IntArrayRef dilation,
  bool ceil_mode)
{
  max_pool2d_with_indices_out_cuda_template(
    output,
    indices,
    input,
    kernel_size,
    stride,
    padding,
    dilation,
    ceil_mode);
  return std::tuple<Tensor&, Tensor&>(output, indices);
}

std::tuple<Tensor, Tensor> max_pool2d_with_indices_cuda(
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  IntArrayRef dilation,
  bool ceil_mode)
{
  Tensor output = at::empty({0}, input.options());
  Tensor indices = at::empty({0}, input.options().dtype(kLong));
  max_pool2d_with_indices_out_cuda_template(
    output,
    indices,
    input,
    kernel_size,
    stride,
    padding,
    dilation,
    ceil_mode);
  return std::tuple<Tensor, Tensor>(output, indices);
}

Tensor& max_pool2d_with_indices_backward_out_cuda(
  Tensor& gradInput,
  const Tensor& gradOutput_,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  IntArrayRef dilation,
  bool ceil_mode,
  const Tensor& indices)
{
  max_pool2d_with_indices_backward_out_cuda_template(
    gradInput,
    gradOutput_,
    input,
    indices,
    kernel_size,
    stride,
    padding,
    dilation,
    ceil_mode);
  return gradInput;
}

Tensor max_pool2d_with_indices_backward_cuda(
  const Tensor& gradOutput_,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  IntArrayRef dilation,
  bool ceil_mode,
  const Tensor& indices)
{
  auto gradInput = at::zeros_like(input);
  max_pool2d_with_indices_backward_out_cuda_template(
    gradInput,
    gradOutput_,
    input,
    indices,
    kernel_size,
    stride,
    padding,
    dilation,
    ceil_mode);
  return gradInput;
}

} // at::native
} // at
