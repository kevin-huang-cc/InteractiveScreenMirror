#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void dumpClass(const char *name) {
    Class c = objc_getClass(name);
    if (!c) { printf("\n=== %s : NOT FOUND ===\n", name); return; }
    printf("\n=== %s (superclass: %s) ===\n", name, class_getName(class_getSuperclass(c)));

    unsigned int n = 0;
    objc_property_t *props = class_copyPropertyList(c, &n);
    printf("-- properties (%u):\n", n);
    for (unsigned i = 0; i < n; i++)
        printf("   %-28s %s\n", property_getName(props[i]), property_getAttributes(props[i]));
    free(props);

    n = 0;
    Method *ms = class_copyMethodList(c, &n);
    printf("-- instance methods (%u):\n", n);
    for (unsigned i = 0; i < n; i++) {
        char types[256];
        method_getReturnType(ms[i], types, sizeof(types));
        printf("   %-40s -> %s  (argc=%u)\n",
               sel_getName(method_getName(ms[i])), types, method_getNumberOfArguments(ms[i]));
    }
    free(ms);
}

int main(void) {
    @autoreleasepool {
        const char *names[] = {
            "CGVirtualDisplay", "CGVirtualDisplayDescriptor",
            "CGVirtualDisplaySettings", "CGVirtualDisplayMode",
        };
        for (int i = 0; i < 4; i++) dumpClass(names[i]);
    }
    return 0;
}
