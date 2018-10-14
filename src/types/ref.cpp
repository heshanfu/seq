#include <cassert>
#include "seq/seq.h"

using namespace seq;
using namespace llvm;

types::RefType::RefType(std::string name) :
    Type(std::move(name), BaseType::get()), Generic(true),
    done(false), root(this), cache(), pendingRealizations(),
    contents(types::RecordType::get({}))
{
}

void types::RefType::setDone()
{
	assert(this == root && !done);
	done = true;

	for (auto& pair : pendingRealizations)
		pair.second->realize(realize(pair.first));

	pendingRealizations.clear();
}

void types::RefType::setContents(types::RecordType *contents)
{
	this->contents = contents;
}

std::string types::RefType::getName() const
{
	if (numGenerics() == 0)
		return name;

	std::string name = this->name + "[";

	for (unsigned i = 0; i < numGenerics(); i++) {
		name += getGeneric(i)->getName();
		if (i < numGenerics() - 1)
			name += ", ";
	}

	name += "]";
	return name;
}

std::string types::RefType::genericName()
{
	return getName();
}

types::Type *types::RefType::realize(std::vector<types::Type *> types)
{
	assert(this == root);

	auto *cached = dynamic_cast<types::RefType *>(findCachedRealizedType(types));

	if (cached)
		return cached;

	if (!done) {
		types::GenericType *proxy = types::GenericType::get();
		pendingRealizations.emplace_back(types, proxy);
		return proxy;
	}

	Generic *x = realizeGeneric(types);
	auto *ref = dynamic_cast<types::RefType *>(x);
	assert(ref);

	for (auto& method : ref->getVTable().methods)
		method.second->resolveTypes();

	for (auto& magic : ref->getVTable().overloads)
		magic.func->resolveTypes();

	return ref;
}

std::vector<types::Type *> types::RefType::deduceTypesFromArgTypes(std::vector<types::Type *> argTypes)
{
	return Generic::deduceTypesFromArgTypes(contents->getTypes(), argTypes);
}

Value *types::RefType::memb(Value *self,
                            const std::string& name,
                            BasicBlock *block)
{
	initFields();
	initOps();

	try {
		return Type::memb(self, name, block);
	} catch (exc::SeqException& e) {
	}

	assert(contents);
	IRBuilder<> builder(block);
	Value *x = builder.CreateLoad(self);

	try {
		return contents->memb(x, name, block);
	} catch (exc::SeqException& e) {
		throw exc::SeqException("type '" + getName() + "' has no member '" + name + "'");
	}
}

types::Type *types::RefType::membType(const std::string& name)
{
	initFields();
	initOps();

	try {
		return Type::membType(name);
	} catch (exc::SeqException& e) {
	}

	try {
		return contents->membType(name);
	} catch (exc::SeqException& e) {
		throw exc::SeqException("type '" + getName() + "' has no member '" + name + "'");
	}
}

Value *types::RefType::setMemb(Value *self,
                               const std::string& name,
                               Value *val,
                               BasicBlock *block)
{
	initFields();
	IRBuilder<> builder(block);
	Value *x = builder.CreateLoad(self);
	x = contents->setMemb(x, name, val, block);
	builder.CreateStore(x, self);
	return self;
}

Value *types::RefType::defaultValue(BasicBlock *block)
{
	return ConstantPointerNull::get(cast<PointerType>(getLLVMType(block->getContext())));
}

void types::RefType::initOps()
{
	if (!vtable.magic.empty())
		return;

	vtable.magic = {
		{"__new__", {}, this, SEQ_MAGIC_CAPT(self, args, b) {
			self = contents->alloc(nullptr, b.GetInsertBlock());
			self = b.CreateBitCast(self, getLLVMType(b.getContext()));
			return self;
		}},

		{"__init__", contents->getTypes(), this, SEQ_MAGIC_CAPT(self, args, b) {
			for (unsigned i = 0; i < args.size(); i++)
				self = setMemb(self, std::to_string(i+1), args[i], b.GetInsertBlock());
			return self;
		}},

		{"__bool__", {}, Bool, SEQ_MAGIC(self, args, b) {
			return b.CreateZExt(b.CreateIsNotNull(self), Bool->getLLVMType(b.getContext()));
		}},
	};
}

void types::RefType::initFields()
{
	assert(contents);
	contents->initFields();
}

bool types::RefType::isAtomic() const
{
	return false;
}

bool types::RefType::is(types::Type *type) const
{
	auto *ref = dynamic_cast<types::RefType *>(type);
	return ref && name == ref->name && Generic::is(ref);
}

unsigned types::RefType::numBaseTypes() const
{
	assert(contents);
	return contents->numBaseTypes();
}

types::Type *types::RefType::getBaseType(unsigned idx) const
{
	assert(contents);
	return contents->getBaseType(idx);
}

Type *types::RefType::getLLVMType(LLVMContext& context) const
{
	std::vector<types::Type *> types = getRealizedTypes();

	for (auto& v : root->cache) {
		if (typeMatch<>(v.first, types)) {
			return PointerType::get(v.second, 0);
		}
	}

	StructType *structType = StructType::create(context, name);
	root->cache.emplace_back(types, structType);
	contents->addLLVMTypesToStruct(structType);
	return PointerType::get(structType, 0);
}

size_t types::RefType::size(Module *module) const
{
	return sizeof(void *);
}

types::RefType *types::RefType::asRef()
{
	return this;
}

Value *types::RefType::make(BasicBlock *block, std::vector<Value *> vals)
{
	assert(contents);
	LLVMContext& context = block->getContext();
	Value *val = contents->defaultValue(block);
	Value *ref = contents->alloc(nullptr, block);
	IRBuilder<> builder(block);
	llvm::Type *type = getLLVMType(context);
	ref = builder.CreateBitCast(ref, type);
	val = builder.CreateBitCast(val, cast<PointerType>(type)->getElementType());
	builder.CreateStore(val, ref);

	for (unsigned i = 0; i < vals.size(); i++)
		ref = setMemb(ref, std::to_string(i+1), vals[i], block);

	return ref;
}

types::RefType *types::RefType::get(std::string name)
{
	return new RefType(std::move(name));
}

types::RefType *types::RefType::clone(Generic *ref)
{
	if (ref->seenClone(this))
		return (types::RefType *)ref->getClone(this);

	types::RefType *x = types::RefType::get(name);
	ref->addClone(this, x);
	setCloneBase(x, ref);

	x->setContents(contents->clone(ref));

	std::vector<MagicOverload> overloadsCloned;
	for (auto& magic : getVTable().overloads)
		overloadsCloned.push_back({magic.name, magic.func->clone(ref)});

	std::map<std::string, BaseFunc *> methodsCloned;
	for (auto& method : getVTable().methods)
		methodsCloned.insert({method.first, method.second->clone(ref)});

	x->getVTable().methods = methodsCloned;
	x->getVTable().overloads = overloadsCloned;
	x->root = root;
	x->done = true;
	return x;
}

types::MethodType::MethodType(types::Type *self, FuncType *func) :
    RecordType({self, func}, {"self", "func"}), self(self), func(func)
{
}

Value *types::MethodType::call(BaseFunc *base,
                               Value *self,
                               const std::vector<Value *>& args,
                               BasicBlock *block)
{
	Value *x = memb(self, "self", block);
	Value *f = memb(self, "func", block);
	std::vector<Value *> argsFull(args);
	argsFull.insert(argsFull.begin(), x);
	return func->call(base, f, argsFull, block);
}

bool types::MethodType::is(types::Type *type) const
{
	return isGeneric(type) &&
	       types::is(getBaseType(0), type->getBaseType(0)) &&
	       types::is(getBaseType(1), type->getBaseType(1));
}

unsigned types::MethodType::numBaseTypes() const
{
	return 2;
}

types::Type *types::MethodType::getBaseType(unsigned idx) const
{
	return idx ? self : func;
}

types::Type *types::MethodType::getCallType(const std::vector<Type *>& inTypes)
{
	std::vector<Type *> inTypesFull(inTypes);
	inTypesFull.insert(inTypesFull.begin(), self);
	return func->getCallType(inTypesFull);
}

Value *types::MethodType::make(Value *self, Value *func, BasicBlock *block)
{
	LLVMContext& context = self->getContext();
	Value *method = UndefValue::get(getLLVMType(context));
	method = setMemb(method, "self", self, block);
	method = setMemb(method, "func", func, block);
	return method;
}

types::MethodType *types::MethodType::get(types::Type *self, types::FuncType *func)
{
	return new MethodType(self, func);
}

types::MethodType *types::MethodType::clone(Generic *ref)
{
	return MethodType::get(self->clone(ref), func->clone(ref));
}
