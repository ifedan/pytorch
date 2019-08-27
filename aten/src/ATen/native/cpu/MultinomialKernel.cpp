#include <ATen/ATen.h>

#include <ATen/Dispatch.h>
#include <ATen/native/Copy.h>
#include <ATen/native/TensorIterator.h>
#include <ATen/native/cpu/Loops.h>
#include <ATen/core/DistributionsHelper.h>

namespace at {
namespace native {
namespace {

template<typename scalar_t>
void multinomial_apply(Tensor& self, const Tensor& prob_dist, const int64_t n_sample, const bool with_replacement, Generator* generator) {
  auto gen = get_generator_or_default<CPUGenerator>(generator, detail::getDefaultCPUGenerator());
  // See Note [Acquire lock when using random generators]
  std::lock_guard<std::mutex> lock(gen->mutex_);

  int64_t n_categories = prob_dist.size(-1);
  int64_t n_dist = prob_dist.dim() > 1 ? prob_dist.size(-2) : 1;

  /* cumulative probability distribution vector */
  Tensor cum_dist = at::empty({n_categories}, prob_dist.options());

  const scalar_t * const prod_dist_ptr = prob_dist.data_ptr<scalar_t>();
  scalar_t * const cum_dist_ptr = cum_dist.data_ptr<scalar_t>();
  int64_t * const self_ptr = self.data_ptr<int64_t>();

  auto prod_dist_stride_0 = prob_dist.dim() > 1 ? prob_dist.stride(-2) : 0;
  auto prod_dist_stride_1 = prob_dist.stride(-1);

  auto cum_dist_stride_0 = cum_dist.stride(0);

  auto self_dist_stride_0 = self.dim() > 1 ? self.stride(-2) : 0;
  auto self_dist_stride_1 = self.stride(-1);

  for (int64_t i = 0; i < n_dist; i++) {
    /* Get normalized cumulative distribution from prob distribution */
    scalar_t sum = 0;
    scalar_t val;
    int n_zeros = 0;
    for (int64_t j = 0; j < n_categories; j++) {
      val = prod_dist_ptr[i * prod_dist_stride_0 + j * prod_dist_stride_1];
      TORCH_CHECK(val >= 0, "invalid multinomial distribution (encountering probability entry < 0)");
      TORCH_CHECK(std::isfinite(val), "invalid multinomial distribution (encountering probability entry = infinity or NaN)");

      sum += val;
      if (val == 0) {
        n_zeros += 1;
      }
      cum_dist_ptr[j * cum_dist_stride_0] = sum;
    }

    TORCH_CHECK(sum > 0, "invalid multinomial distribution (sum of probabilities <= 0)");
    TORCH_CHECK(with_replacement || (n_categories - n_zeros >= n_sample),
        "invalid multinomial distribution (with replacement=False, not enough non-negative category to sample)");

    /* normalize cumulative probability distribution so that last val is 1
    i.e. doesn't assume original prob_dist row sums to one */
    if ((sum > 0) || ((sum < 1.00001) && (sum > 0.99999))) {
      for (int64_t j = 0; j < n_categories; j++) {
        cum_dist_ptr[j * cum_dist_stride_0] /= sum;
      }
    }

    for (int64_t j = 0; j < n_sample; j++) {
      /* sample a probability mass from a uniform distribution */
      at::uniform_real_distribution<double> uniform(0, 1);
      double uniform_sample = uniform(gen);
      /* Do a binary search for the slot in which the prob falls
      ie cum_dist[row][slot-1] < uniform_prob < cum_distr[row][slot] */
      int left_pointer = 0;
      int right_pointer = n_categories;
      int mid_pointer;
      scalar_t cum_prob;
      int sample_idx;
      /* Make sure the last cumulative distribution bucket sums to 1 */
      cum_dist_ptr[(n_categories - 1) * cum_dist_stride_0] = 1;

      while(right_pointer - left_pointer > 0) {
        mid_pointer = left_pointer + (right_pointer - left_pointer) / 2;
        cum_prob = cum_dist_ptr[mid_pointer * cum_dist_stride_0];
        if (cum_prob < uniform_sample) {
          left_pointer = mid_pointer + 1;
        }
        else {
          right_pointer = mid_pointer;
        }
      }
      sample_idx = left_pointer;

      /* store in result tensor (will be incremented for lua compat by wrapper) */
      self_ptr[i * self_dist_stride_0 + j * self_dist_stride_1] = sample_idx;

      /* Once a sample is drawn, it cannot be drawn again. ie sample without replacement */
      if (!with_replacement && j < n_sample - 1) {
        /* update cumulative distribution so that sample cannot be drawn again */
        scalar_t diff;
        scalar_t new_val = 0;
        scalar_t sum;

        if (sample_idx != 0) {
          new_val = cum_dist_ptr[(sample_idx - 1) * cum_dist_stride_0];
        }
        /* marginal cumulative mass (i.e. original probability) of sample */
        diff = cum_dist_ptr[sample_idx * cum_dist_stride_0] - new_val;
        /* new sum of marginals is not one anymore... */
        sum = 1.0 - diff;
        for (int64_t k = 0; k < n_categories; k++) {
          new_val = cum_dist_ptr[k * cum_dist_stride_0];
          if (k >= sample_idx) {
            /* remove sampled probability mass from later cumulative probabilities */
            new_val -= diff;
          }
          /* make total marginals sum to one */
          new_val /= sum;
          cum_dist_ptr[k * cum_dist_stride_0] = new_val;
        }
      }
    }
  }
}

static void multinomial_kernel_impl(Tensor& result, const Tensor& self, const int64_t n_sample, const bool with_replacement, Generator *gen) {
  AT_DISPATCH_FLOATING_TYPES(self.scalar_type(), "multinomial", [&] {
    multinomial_apply<scalar_t>(result, self, n_sample, with_replacement, gen);
  });
}

}

REGISTER_DISPATCH(multinomial_stub, &multinomial_kernel_impl);

}
}
