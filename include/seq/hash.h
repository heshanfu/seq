#ifndef SEQ_HASH_H
#define SEQ_HASH_H

#include <string>
#include "stage.h"

namespace seq {
	class Hash : public Stage {
	private:
		llvm::Function *func;
		SeqHash hash;
	public:
		Hash(std::string name, SeqHash hash);
		void codegen(llvm::Module *module) override;
		void finalize(llvm::Module *module, llvm::ExecutionEngine *eng) override;
		static Hash& make(std::string name, SeqHash hash);
	};
}

#endif /* SEQ_HASH_H */