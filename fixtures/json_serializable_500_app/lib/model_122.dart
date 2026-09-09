import 'package:json_annotation/json_annotation.dart';

part 'model_122.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model122 {
  const Model122({required this.id, required this.value});

  final int id;
  final String value;

  factory Model122.fromJson(Map<String, dynamic> json) =>
      _$Model122FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model122ToJson(this);
}
