#include <iostream>
#include <cstdio>
#include <cstdlib>
#include <fstream>


#include "flamegpu/flame_api.h"
#include "flamegpu/runtime/flamegpu_api.h"
#include "flamegpu/io/factory.h"

FLAMEGPU_AGENT_FUNCTION(output_message, MsgNone, MsgSpatial3D) {
    FLAMEGPU->message_out.setVariable<int>("id", FLAMEGPU->getVariable<int>("id"));
    FLAMEGPU->message_out.setLocation(
        FLAMEGPU->getVariable<float>("x"),
        FLAMEGPU->getVariable<float>("y"),
        FLAMEGPU->getVariable<float>("z"));
    return ALIVE;
}
FLAMEGPU_AGENT_FUNCTION(move, MsgSpatial3D, MsgNone) {
    const int ID = FLAMEGPU->getVariable<int>("id");
    const float REPULSE_FACTOR = FLAMEGPU->environment.get<float>("repulse");
    const float RADIUS = FLAMEGPU->message_in.radius();
    float fx = 0.0;
    float fy = 0.0;
    float fz = 0.0;
    const float x1 = FLAMEGPU->getVariable<float>("x");
    const float y1 = FLAMEGPU->getVariable<float>("y");
    const float z1 = FLAMEGPU->getVariable<float>("z");
    int count = 0;
    for (const auto &message : FLAMEGPU->message_in(x1, y1, z1)) {
        if (message.getVariable<int>("id") != ID) {
            const float x2 = message.getVariable<float>("x");
            const float y2 = message.getVariable<float>("y");
            const float z2 = message.getVariable<float>("z");
            float x21 = x2 - x1;
            float y21 = y2 - y1;
            float z21 = z2 - z1;
            const float separation = cbrt(x21*x21 + y21*y21 + z21*z21);
            if (separation < RADIUS && separation > 0.0f) {
                float k = sinf((separation / RADIUS)*3.141*-2)*REPULSE_FACTOR;
                // Normalise without recalculating separation
                x21 /= separation;
                y21 /= separation;
                z21 /= separation;
                fx += k * x21;
                fy += k * y21;
                fz += k * z21;
                count++;
            }
        }
    }
    fx /= count > 0 ? count : 1;
    fy /= count > 0 ? count : 1;
    fz /= count > 0 ? count : 1;
    FLAMEGPU->setVariable<float>("x", x1 + fx);
    FLAMEGPU->setVariable<float>("y", y1 + fy);
    FLAMEGPU->setVariable<float>("z", z1 + fz);
    FLAMEGPU->setVariable<float>("drift", cbrt(fx*fx + fy*fy + fz*fz));
    return ALIVE;
}
FLAMEGPU_STEP_FUNCTION(Validation) {
    static float prevTotalDrift = FLT_MAX;
    static unsigned int driftDropped = 0;
    static unsigned int driftIncreased = 0;
    // This value should decline? as the model moves towards a steady equlibrium state
    // Once an equilibrium state is reached, it is likely to oscillate between 2-4? values
    float totalDrift = FLAMEGPU->agent("Circle").sum<float>("drift");
    if (totalDrift <= prevTotalDrift)
        driftDropped++;
    else
        driftIncreased++;
    prevTotalDrift = totalDrift;
    // printf("Avg Drift: %g\n", totalDrift / FLAMEGPU->agent("Circle").count());
    printf("%.2f%% Drift correct\n", 100 * driftDropped / static_cast<float>(driftDropped + driftIncreased));
}
void export_data(std::shared_ptr<AgentPopulation> pop, const char *filename);
int main(int argc, const char ** argv) {
    const unsigned int AGENT_COUNT = 16384;
    ModelDescription model("Circles_BruteForce_example");

    {   // Location message
        MsgSpatial3D::Description &message = model.newMessage<MsgSpatial3D>("location");
        message.newVariable<int>("id");
        const float max_bound = static_cast<float>(floor(cbrt(AGENT_COUNT)));
        message.setRadius(1.0f);
        message.setMin(0, 0, 0);
        message.setMax(max_bound, max_bound, max_bound);
    }
    {   // Circle agent
        AgentDescription &agent = model.newAgent("Circle");
        agent.newVariable<int>("id");
        agent.newVariable<float>("x");
        agent.newVariable<float>("y");
        agent.newVariable<float>("z");
        agent.newVariable<float>("drift");  // Store the distance moved here, for validation
        agent.newFunction("output_message", output_message).setMessageOutput("location");
        agent.newFunction("move", move).setMessageInput("location");
    }

    /**
     * GLOBALS
     */
    {
        EnvironmentDescription &env = model.Environment();
        env.add("repulse", 0.05f);
    }

    /**
     * Control flow
     */     
    {   // Attach init/step/exit functions and exit condition
        model.addStepFunction(Validation);
    }

    {   // Layer #1
        LayerDescription &layer = model.newLayer();
        layer.addAgentFunction(output_message);
    }
    {   // Layer #2
        LayerDescription &layer = model.newLayer();
        layer.addAgentFunction(move);
    }

    /**
     * Create Model Runner
     */
    CUDAAgentModel cuda_model(model);

    /**
     * Initialisation
     */
    cuda_model.initialise(argc, argv);
    if (cuda_model.getSimulationConfig().xml_input_file.empty()) {
        // Currently population has not been init, so generate an agent population on the fly
        std::default_random_engine rng;
        std::uniform_real_distribution<float> dist(0.0f, static_cast<float>(floor(cbrt(AGENT_COUNT))));
        AgentPopulation population(model.Agent("Circle"), AGENT_COUNT);
        for (unsigned int i = 0; i < AGENT_COUNT; i++) {
            AgentInstance instance = population.getNextInstance();
            instance.setVariable<int>("id", i);
            instance.setVariable<float>("x", dist(rng));
            instance.setVariable<float>("y", dist(rng));
            instance.setVariable<float>("z", dist(rng));
        }
        cuda_model.setPopulationData(population);
    }

    /**
     * Execution
     */
    // This mode of execution allows the PRIMAGE visualiser to be used (2020-01-07)
    while (cuda_model.getStepCounter() < cuda_model.getSimulationConfig().steps && cuda_model.step()) {
        std::unordered_map<std::string, std::shared_ptr<AgentPopulation>> pops;
        auto a = std::make_shared<AgentPopulation>(model.getAgent("Circle"));
        cuda_model.getPopulationData(*a);
        export_data(a, (std::to_string(cuda_model.getStepCounter()-1)+".bin").c_str());
    }

    cuda_model.simulate();
    getchar();

    /**
     * Export Pop
     */
    // cuda_model.output();
    // Based on Simulation::output() // That can't currently be called
    std::unordered_map<std::string, std::shared_ptr<AgentPopulation>> pops;
    auto a = std::make_shared<AgentPopulation>(model.getAgent("Circle"));
    cuda_model.getPopulationData(*a);
    pops.emplace("Circle", a);
    StateWriter *write__ = WriterFactory::createWriter(pops, cuda_model.getStepCounter(), "end.xml");
    write__->writeStates();
    // export_data(a, "test.bin");
    getchar();
    return 0;
}

void export_data(std::shared_ptr<AgentPopulation> pop, const char *filename) {
    // Basic binary export function, so that I can use the visualiser i made for kenneths model
    std::ofstream ofs;
    ofs.open(filename, std::ofstream::out | std::ofstream::trunc | std::ofstream::binary);
    if (ofs.is_open()) {
        float garbage[6];  // Need to begin with 6 floats, doesn't matter what they are
        // Write data
        ofs.write(reinterpret_cast<const char*>(garbage), sizeof(float)*6);
        ofs.write(reinterpret_cast<const char*>(pop->getReadOnlyStateMemory().getReadOnlyMemoryVector("x").getReadOnlyDataPtr()), sizeof(float)*pop->getCurrentListSize());
        ofs.write(reinterpret_cast<const char*>(pop->getReadOnlyStateMemory().getReadOnlyMemoryVector("y").getReadOnlyDataPtr()), sizeof(float)*pop->getCurrentListSize());
        ofs.write(reinterpret_cast<const char*>(pop->getReadOnlyStateMemory().getReadOnlyMemoryVector("z").getReadOnlyDataPtr()), sizeof(float)*pop->getCurrentListSize());
        ofs.write(reinterpret_cast<const char*>(pop->getReadOnlyStateMemory().getReadOnlyMemoryVector("drift").getReadOnlyDataPtr()), sizeof(float)*pop->getCurrentListSize());
        ofs.close();
    }
}