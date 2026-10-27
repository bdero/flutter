// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/fml/synchronization/count_down_latch.h"
#include "flutter/testing/testing.h"
#include "impeller/core/device_buffer_descriptor.h"
#include "impeller/core/formats.h"
#include "impeller/core/texture_descriptor.h"
#include "impeller/playground/playground_test.h"
#include "impeller/renderer/backend/metal/allocator_mtl.h"
#include "impeller/renderer/backend/metal/context_mtl.h"
#include "impeller/renderer/backend/metal/device_buffer_mtl.h"
#include "impeller/renderer/backend/metal/formats_mtl.h"
#include "impeller/renderer/backend/metal/texture_mtl.h"
#include "impeller/renderer/blit_pass.h"
#include "impeller/renderer/capabilities.h"
#include "impeller/renderer/command_buffer.h"
#include "impeller/renderer/command_queue.h"

#include <QuartzCore/CAMetalLayer.h>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

#include "gtest/gtest.h"

namespace impeller {
namespace testing {

using AllocatorMTLTest = PlaygroundTest;
INSTANTIATE_METAL_PLAYGROUND_SUITE(AllocatorMTLTest);

TEST_P(AllocatorMTLTest, DebugTraceMemoryStatistics) {
  auto& context_mtl = ContextMTL::Cast(*GetContext());
  const auto& allocator = context_mtl.GetResourceAllocator();

  EXPECT_EQ(allocator->DebugGetHeapUsage().ConvertTo<MebiBytes>().GetSize(),
            0u);

  // Memoryless texture does not increase allocated size.
  {
    TextureDescriptor desc;
    desc.format = PixelFormat::kR8G8B8A8UNormInt;
    desc.storage_mode = StorageMode::kDeviceTransient;
    desc.size = {1024, 1024};
    auto texture_1 = allocator->CreateTexture(desc);

    // Private storage texture increases allocated size.
    desc.storage_mode = StorageMode::kDevicePrivate;
    auto texture_2 = allocator->CreateTexture(desc);

#ifdef IMPELLER_DEBUG
    EXPECT_EQ(allocator->DebugGetHeapUsage().ConvertTo<MebiBytes>().GetSize(),
              4u);
#else
    EXPECT_EQ(allocator->DebugGetHeapUsage().ConvertTo<MebiBytes>().GetSize(),
              0u);
#endif  // IMPELLER_DEBUG

    // Host storage texture increases allocated size.
    desc.storage_mode = StorageMode::kHostVisible;
    auto texture_3 = allocator->CreateTexture(desc);

#ifdef IMPELLER_DEBUG
    EXPECT_EQ(allocator->DebugGetHeapUsage().ConvertTo<MebiBytes>().GetSize(),
              8u);
#else
    EXPECT_EQ(allocator->DebugGetHeapUsage().ConvertTo<MebiBytes>().GetSize(),
              0u);
#endif  // IMPELLER_DEBUG
  }

  // After all textures are out of scope, memory has been decremented.
  EXPECT_EQ(allocator->DebugGetHeapUsage().ConvertTo<MebiBytes>().GetSize(),
            0u);
}

TEST_P(AllocatorMTLTest, ManagedMemory) {
  auto& context_mtl = ContextMTL::Cast(*GetContext());
  auto allocator = std::make_unique<AllocatorMTL>(context_mtl.GetMTLDevice(),
                                                  "test-allocator");
  allocator->DebugSetSupportsUMA(false);

  DeviceBufferDescriptor desc;
  desc.size = 100;
  desc.storage_mode = StorageMode::kHostVisible;

  auto buffer = allocator->CreateBuffer(desc);
  ASSERT_TRUE(buffer);

  EXPECT_NE(buffer->OnGetContents(), nullptr);
}

TEST_P(AllocatorMTLTest, TextureReadbackIntoManagedMemory) {
  auto context = GetContext();
  auto& context_mtl = ContextMTL::Cast(*context);
  auto managed_allocator = std::make_unique<AllocatorMTL>(
      context_mtl.GetMTLDevice(), "test-allocator");
  managed_allocator->DebugSetSupportsUMA(false);

  constexpr size_t kBytes = 4 * 4 * 4;
  std::vector<uint8_t> pixels(kBytes);
  for (size_t i = 0; i < kBytes; i++) {
    pixels[i] = static_cast<uint8_t>(i * 3 + 1);
  }

  DeviceBufferDescriptor staging_desc;
  staging_desc.size = kBytes;
  staging_desc.storage_mode = StorageMode::kHostVisible;
  auto staging = context->GetResourceAllocator()->CreateBuffer(staging_desc);
  ASSERT_TRUE(staging);
  ASSERT_TRUE(staging->CopyHostBuffer(pixels.data(), Range{0, kBytes}));

  TextureDescriptor texture_desc;
  texture_desc.format = PixelFormat::kR8G8B8A8UNormInt;
  texture_desc.storage_mode = StorageMode::kDevicePrivate;
  texture_desc.size = {4, 4};
  auto texture = context->GetResourceAllocator()->CreateTexture(texture_desc);
  ASSERT_TRUE(texture);

  DeviceBufferDescriptor readback_desc;
  readback_desc.size = kBytes;
  readback_desc.storage_mode = StorageMode::kHostVisible;
  auto readback = managed_allocator->CreateBuffer(readback_desc);
  ASSERT_TRUE(readback);
  ASSERT_EQ(DeviceBufferMTL::Cast(*readback).GetMTLBuffer().storageMode,
            MTLStorageModeManaged);
  memset(readback->OnGetContents(), 0, kBytes);
  readback->Flush();

  auto command_buffer = context->CreateCommandBuffer();
  auto pass = command_buffer->CreateBlitPass();
  ASSERT_TRUE(pass->AddCopy(DeviceBuffer::AsBufferView(staging), texture));
  ASSERT_TRUE(pass->AddCopy(texture, readback));
  ASSERT_TRUE(pass->EncodeCommands());

  fml::CountDownLatch latch(1);
  ASSERT_TRUE(
      context->GetCommandQueue()
          ->Submit({command_buffer},
                   [&latch](CommandBuffer::Status) { latch.CountDown(); })
          .ok());
  latch.Wait();

  readback->Invalidate();
  EXPECT_EQ(memcmp(readback->OnGetContents(), pixels.data(), kBytes), 0);
}

}  // namespace testing
}  // namespace impeller
