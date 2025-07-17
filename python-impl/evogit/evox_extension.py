from functools import partial
import logging
import torch
import random
import op
from evox.core import Problem

logger = logging.getLogger("evogit")

# commit_id is either sha1 - 160 bits or sha256 - 256 bits
# we use 20 bytes to represent the commit id using sha1
# and 32 bytes to represent the commit id using sha256


def array_to_hex(array):
    return array.numpy().tobytes().hex()


def hex_to_array(hex_string):
    return torch.frombuffer(bytearray.fromhex(hex_string), dtype=torch.uint8)


HASH_BYTE_LENGTH = {
    "sha1": 20,
    "sha256": 32,
}


def get_upper_bound(config):
    return torch.full((HASH_BYTE_LENGTH[config.git_hash],), 255, dtype=torch.uint8)


def get_lower_bound(config):
    return torch.zeros((HASH_BYTE_LENGTH[config.git_hash],), dtype=torch.uint8)


def update_branches(config, pop):
    pop = [array_to_hex(individual) for individual in pop]
    op.update_branches(config, pop)
    op.prune_commits(config)


def git_update(config, generation):
    handlers = []
    if config.fetch_every > 0 and generation % config.fetch_every == 0:
        handlers.extend(op.fetch_remote(config))
    if config.push_every > 0 and generation % config.push_every == 0:
        handlers.extend(op.push_local_branches(config))

    for proc in handlers:
        proc.wait()


def evogit_git_crossover(config, pop):
    pop = [array_to_hex(individual) for individual in pop]
    pop_size = len(pop)
    offspring = []
    retry = 0
    for _ in range(pop_size):
        idx1, idx2 = torch.randint(0, pop_size, (2,))
        commit1, commit2 = pop[idx1], pop[idx2]
        while (
            not op.is_novel_merge(config, commit1, commit2)
            and retry < config.max_merge_retry
        ):
            idx1, idx2 = torch.randint(0, pop_size, (2,))
            commit1, commit2 = pop[idx1], pop[idx2]
            retry += 1

        new_commit = op.git_crossover(
            config, random.randint(0, 2 << 31), commit1, commit2
        )
        offspring.append(hex_to_array(new_commit))

    logger.info(f"Git crossover stats: pop_size={pop_size}, retry={retry}")

    return torch.stack(offspring)


def git_crossover(config, pop):
    pop_size, dim = pop.shape

    return evogit_git_crossover(config, pop)


def evogit_mutation(config, llm_backend, pop):
    seeds = [random.randint(0, 2 << 31) for _ in range(pop.shape[0])]
    commits = [array_to_hex(ind) for ind in pop]
    new_commits = op.llm_constrained_mutation(config, llm_backend, seeds, commits)
    offspring = [hex_to_array(new_commit) for new_commit in new_commits]
    return torch.stack(offspring)


def evogit_crossover(config, pop):
    n_pair, _, dim = pop.shape
    offspring = []
    for commit1, commit2 in pop:
        commit1 = array_to_hex(commit1)
        commit2 = array_to_hex(commit2)
        new_commit = op.git_crossover(
            config, random.randint(0, 2 << 31), commit1, commit2
        )
        offspring.append(hex_to_array(new_commit))

    offspring = torch.stack(offspring)
    return offspring


def evaluate(config, pool, pop):
    pop = [array_to_hex(individual) for individual in pop]
    logger = logging.getLogger("evogit")
    logger.info(pop)

    # 1. prepare worktrees  2. evaluate  3. update notes  4. cleanup worktrees
    unique_pop = list(set(pop))  # deduplicate
    worktrees = op.prepare_temp_worktrees(config, unique_pop)
    outputs = list(pool.map(partial(op.evaluate_code, config), unique_pop, worktrees))
    op.update_notes(config, unique_pop, outputs)
    op.cleanup_temp_worktrees(config)

    illegal_value = 1e8

    commit_to_fitness = {}
    for commit_id, output in zip(unique_pop, outputs):
        performance_cost, time_cost = op.decode_result(output, illegal_value)
        commit_to_fitness[commit_id] = [performance_cost, time_cost]
    fitness = [commit_to_fitness[commit_id] for commit_id in pop]
    fitness = torch.tensor(fitness)
    assert fitness.dtype == torch.float32
    return fitness


class EvoGitProblem(Problem):
    def __init__(self, config):
        super().__init__()
        self.config = config
        self.llm_backend = config.llm_backend

    def evaluate(self, pop):
        prev, new = pop
        prev = [array_to_hex(commit) for commit in prev]
        new = [array_to_hex(commit) for commit in new]
        op.lint_code_base(self.config, new)
        # compare the previous and new commits
        # return True if the new commit is better than the previous one
        seeds = [random.randint(0, 2 << 31) for _ in range(len(prev))]
        result = op.llm_diff_compare(self.config, self.llm_backend, seeds, prev, new)
        result = torch.tensor(result)
        return result


def init_population(config, pop_size):
    pop = op.get_initial_branches(config, pop_size)
    pop = [hex_to_array(commit) for commit in pop]
    return torch.stack(pop)
