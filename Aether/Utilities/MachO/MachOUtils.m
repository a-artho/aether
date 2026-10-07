// Mach-O patching validates every slice before writing mapped bytes.
#import "MachOUtils.h"

#define SDK_VERSION_26_0_0 0x1A0000

typedef struct { size_t offset; size_t size; size_t architectureOffset; BOOL wide; BOOL swap; } LCSlice;

static NSString *LCMapWritable(const char *path, int *fd, void **map, size_t *size) {
    *fd = open(path, O_RDWR, 0600);
    if (*fd < 0) return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
    struct stat info = {0};
    if (fstat(*fd, &info) != 0 || info.st_size < sizeof(uint32_t) || (uint64_t)info.st_size > SIZE_MAX) {
        close(*fd);
        return @"Invalid or truncated Mach-O file";
    }
    *size = (size_t)info.st_size;
    *map = mmap(NULL, *size, PROT_READ | PROT_WRITE, MAP_SHARED, *fd, 0);
    if (*map == MAP_FAILED) {
        close(*fd);
        return @"Failed to map Mach-O file";
    }
    return nil;
}

static NSString *LCSlices(void *map, size_t size, NSMutableData *slices) {
    uint32_t magic;
    memcpy(&magic, map, sizeof(magic));
    BOOL fat = magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
    if (!fat) {
        if (magic != MH_MAGIC_64) return @"Unsupported Mach-O format";
        LCSlice slice = {0, size, 0, NO, NO};
        [slices appendBytes:&slice length:sizeof(slice)];
        return nil;
    }
    if (size < sizeof(struct fat_header)) return @"Truncated fat header";
    struct fat_header header;
    memcpy(&header, map, sizeof(header));
    BOOL swap = magic == FAT_CIGAM || magic == FAT_CIGAM_64;
    BOOL wide = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
    uint32_t count = swap ? OSSwapInt32(header.nfat_arch) : header.nfat_arch;
    size_t archSize = wide ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
    if (count == 0 || count > (size - sizeof(header)) / archSize) return @"Truncated architecture table";
    for (uint32_t i = 0; i < count; i++) {
        size_t archOffset = sizeof(header) + i * archSize;
        uint64_t offset, length;
        if (wide) {
            struct fat_arch_64 arch;
            memcpy(&arch, (uint8_t *)map + archOffset, sizeof(arch));
            offset = swap ? OSSwapInt64(arch.offset) : arch.offset;
            length = swap ? OSSwapInt64(arch.size) : arch.size;
        } else {
            struct fat_arch arch;
            memcpy(&arch, (uint8_t *)map + archOffset, sizeof(arch));
            offset = swap ? OSSwapInt32(arch.offset) : arch.offset;
            length = swap ? OSSwapInt32(arch.size) : arch.size;
        }
        if (offset < sizeof(header) + count * archSize || offset > size || length > size - offset || length < sizeof(struct mach_header)) return @"Invalid architecture slice bounds";
        LCSlice slice = {(size_t)offset, (size_t)length, archOffset, wide, swap};
        [slices appendBytes:&slice length:sizeof(slice)];
    }
    return nil;
}

static NSString *LCBuildVersionOffset(void *map, LCSlice slice, size_t *buildOffset) {
    *buildOffset = SIZE_MAX;
    uint32_t magic;
    memcpy(&magic, (uint8_t *)map + slice.offset, sizeof(magic));
    if (magic == MH_MAGIC || magic == MH_CIGAM) return nil;
    if (slice.size < sizeof(struct mach_header_64)) return @"Truncated Mach-O header";
    struct mach_header_64 header;
    memcpy(&header, (uint8_t *)map + slice.offset, sizeof(header));
    if (header.magic != MH_MAGIC_64) return @"Unsupported non-64-bit slice";
    if (header.sizeofcmds > slice.size - sizeof(header) || header.ncmds > header.sizeofcmds / sizeof(struct load_command)) return @"Invalid load command table";
    size_t offset = sizeof(header), end = offset + header.sizeofcmds;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (offset > end || sizeof(struct load_command) > end - offset) return @"Truncated load command";
        struct load_command cmd;
        memcpy(&cmd, (uint8_t *)map + slice.offset + offset, sizeof(cmd));
        if (cmd.cmdsize < sizeof(cmd) || cmd.cmdsize > end - offset) return @"Invalid load command size";
        if (cmd.cmd == LC_BUILD_VERSION) {
            if (cmd.cmdsize < sizeof(struct build_version_command)) return @"Truncated build version command";
            struct build_version_command build;
            memcpy(&build, (uint8_t *)map + slice.offset + offset, sizeof(build));
            if (build.ntools > (cmd.cmdsize - sizeof(build)) / sizeof(struct build_tool_version)) return @"Truncated build tool table";
            *buildOffset = slice.offset + offset + offsetof(struct build_version_command, sdk);
        }
        offset += cmd.cmdsize;
    }
    return nil;
}

// ARM64e fixup originates from LiveContainer (Apache-2.0), bundled when compiled.
// https://github.com/LiveContainer/LiveContainer/commit/3a029b6bb36c11cc05784a8840d41c7e46af1540
NSString *LCPatchMachOFixupARM64eSlice(const char *path) {
    int fd; void *map; size_t size;
    NSString *error = LCMapWritable(path, &fd, &map, &size);
    if (error) return error;
    NSMutableData *data = [NSMutableData data];
    error = LCSlices(map, size, data);
    if (!error) {
        const LCSlice *slices = data.bytes;
        for (size_t i = 0; i < data.length / sizeof(LCSlice); i++) {
            LCSlice slice = slices[i];
            if (slice.architectureOffset == 0) continue;
            // cputype/cpusubtype are the first two fields in both fat arch formats.
            uint32_t fields[2];
            memcpy(fields, (uint8_t *)map + slice.architectureOffset, sizeof(fields));
            uint32_t cpu = slice.swap ? OSSwapInt32(fields[0]) : fields[0];
            uint32_t subtype = slice.swap ? OSSwapInt32(fields[1]) : fields[1];
            if (cpu != CPU_TYPE_ARM64 || subtype != CPU_SUBTYPE_ARM64E) continue;
            if (slice.size < sizeof(struct mach_header_64)) { error = @"Truncated ARM64e slice header"; break; }
            struct mach_header_64 header;
            memcpy(&header, (uint8_t *)map + slice.offset, sizeof(header));
            if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64) { error = @"Invalid ARM64e slice header"; break; }
            uint32_t patched = header.cpusubtype | CPU_SUBTYPE_LIB64;
            memcpy((uint8_t *)map + slice.offset + offsetof(struct mach_header_64, cpusubtype), &patched, sizeof(patched));
            uint32_t archSubtype = slice.swap ? OSSwapInt32(patched) : patched;
            memcpy((uint8_t *)map + slice.architectureOffset + sizeof(uint32_t), &archSubtype, sizeof(archSubtype));
            break;
        }
    }
    munmap(map, size); close(fd);
    return error;
}

NSString *LCPatchMachOForSDK26(const char *path) {
    int fd; void *map; size_t size;
    NSString *error = LCMapWritable(path, &fd, &map, &size);
    if (error) return error;
    NSMutableData *data = [NSMutableData data], *patches = [NSMutableData data];
    error = LCSlices(map, size, data);
    if (!error) {
        const LCSlice *slices = data.bytes;
        for (size_t i = 0; i < data.length / sizeof(LCSlice); i++) {
            size_t offset;
            error = LCBuildVersionOffset(map, slices[i], &offset);
            if (error) break;
            if (offset != SIZE_MAX) [patches appendBytes:&offset length:sizeof(offset)];
        }
    }
    if (!error) {
        const size_t *offsets = patches.bytes;
        uint32_t sdk = SDK_VERSION_26_0_0;
        for (size_t i = 0; i < patches.length / sizeof(size_t); i++) memcpy((uint8_t *)map + offsets[i], &sdk, sizeof(sdk));
    }
    munmap(map, size); close(fd);
    return error ?: (patches.length ? @"Patched LC_BUILD_VERSION to SDK 26.0" : @"LC_BUILD_VERSION not found");
}

#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSSLOT_ENTITLEMENTS 5

typedef struct __attribute__((packed)) { uint32_t type; uint32_t offset; } LCBlobIndex;
typedef struct __attribute__((packed)) { uint32_t magic; uint32_t length; uint32_t count; LCBlobIndex index[]; } LCSuperBlob;
typedef struct __attribute__((packed)) { uint32_t magic; uint32_t length; } LCBlob;

NSData *LCGetMachOEntitlements(const char *path) {
	int fd = open(path, O_RDONLY);
	if (fd < 0) return nil;

	struct stat s = {0};
	if (fstat(fd, &s) != 0 || s.st_size < sizeof(uint32_t)) {
		close(fd);
		return nil;
	}

	size_t fileSize = s.st_size;
	uint8_t *map = mmap(NULL, fileSize, PROT_READ, MAP_PRIVATE, fd, 0);
	if (map == MAP_FAILED) {
		close(fd);
		return nil;
	}

	NSData *resultXML = nil;
	uint8_t *sliceBase = map;
	size_t sliceSize = fileSize;
	uint32_t magic = *(uint32_t *)map;

	if (magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
		BOOL is64 = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
		BOOL swap = (magic == FAT_CIGAM || magic == FAT_CIGAM_64);

		if (fileSize < sizeof(struct fat_header)) goto bad;
		
		struct fat_header *fatHeader = (struct fat_header *)map;
		uint32_t nfat = swap ? OSSwapInt32(fatHeader->nfat_arch) : fatHeader->nfat_arch;
		if (nfat == 0) goto bad;

		size_t archHeaderSize = is64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
		if (sizeof(struct fat_header) + archHeaderSize > fileSize) goto bad;

		uint64_t sliceOff = 0, sliceLen = 0;
		if (is64) {
			struct fat_arch_64 *arch = (struct fat_arch_64 *)(map + sizeof(struct fat_header));
			sliceOff = swap ? OSSwapInt64(arch->offset) : arch->offset;
			sliceLen = swap ? OSSwapInt64(arch->size) : arch->size;
		} else {
			struct fat_arch *arch = (struct fat_arch *)(map + sizeof(struct fat_header));
			sliceOff = swap ? OSSwapInt32(arch->offset) : arch->offset;
			sliceLen = swap ? OSSwapInt32(arch->size) : arch->size;
		}

		if (sliceOff > fileSize || sliceLen > fileSize - sliceOff) goto bad;
		sliceBase = map + sliceOff;
		sliceSize = (size_t)sliceLen;
	}

	if (sliceSize < sizeof(struct mach_header_64)) goto bad;
	struct mach_header_64 *header = (struct mach_header_64 *)sliceBase;
	if (header->magic != MH_MAGIC_64) goto bad;

	if (header->sizeofcmds > sliceSize - sizeof(struct mach_header_64)) goto bad;

	size_t offset = sizeof(struct mach_header_64);
	size_t endOfCmds = offset + header->sizeofcmds;
	struct linkedit_data_command *csCmd = NULL;

	for (uint32_t i = 0; i < header->ncmds; i++) {
		if (offset > endOfCmds || sizeof(struct load_command) > endOfCmds - offset) goto bad;
		
		struct load_command *cmd = (struct load_command *)(sliceBase + offset);
		
		if (cmd->cmdsize < sizeof(struct load_command) || cmd->cmdsize > endOfCmds - offset) goto bad;

		if (cmd->cmd == LC_CODE_SIGNATURE && cmd->cmdsize >= sizeof(struct linkedit_data_command)) {
			csCmd = (struct linkedit_data_command *)cmd;
			break;
		}
		offset += cmd->cmdsize;
	}

	if (!csCmd || csCmd->dataoff > sliceSize || csCmd->datasize > sliceSize - csCmd->dataoff) goto bad;

	uint8_t *csBase = sliceBase + csCmd->dataoff;
	uint32_t csSize = csCmd->datasize;
	if (csSize < sizeof(LCSuperBlob)) goto bad;

	LCSuperBlob *superBlob = (LCSuperBlob *)csBase;
	if (OSSwapBigToHostInt32(superBlob->magic) != CSMAGIC_EMBEDDED_SIGNATURE) goto bad;

	uint32_t count = OSSwapBigToHostInt32(superBlob->count);
	if (count > (csSize - sizeof(LCSuperBlob)) / sizeof(LCBlobIndex)) goto bad;

	for (uint32_t i = 0; i < count; i++) {
		if (OSSwapBigToHostInt32(superBlob->index[i].type) != CSSLOT_ENTITLEMENTS) continue;

		uint32_t blobOff = OSSwapBigToHostInt32(superBlob->index[i].offset);
		if (blobOff > csSize || sizeof(LCBlob) > csSize - blobOff) goto bad;

		LCBlob *blob = (LCBlob *)(csBase + blobOff);
		uint32_t blobLen = OSSwapBigToHostInt32(blob->length);
		if (blobLen <= sizeof(LCBlob) || blobLen > csSize - blobOff) goto bad;

		NSData *plistData = [NSData dataWithBytes:csBase + blobOff + sizeof(LCBlob)
										   length:blobLen - sizeof(LCBlob)];

		NSDictionary *entitlements = [NSPropertyListSerialization propertyListWithData:plistData
																			   options:NSPropertyListImmutable
																				format:nil
																				 error:nil];
		if (entitlements) {
			resultXML = [NSPropertyListSerialization dataWithPropertyList:entitlements
																   format:NSPropertyListXMLFormat_v1_0
																  options:0
																	error:nil];
		}
		break;
	}

bad:
	munmap(map, fileSize);
	close(fd);
	return resultXML;
}
