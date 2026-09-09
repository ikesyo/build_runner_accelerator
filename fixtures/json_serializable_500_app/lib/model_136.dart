import 'package:json_annotation/json_annotation.dart';

part 'model_136.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model136 {
  const Model136({required this.id, required this.value});

  final int id;
  final String value;

  factory Model136.fromJson(Map<String, dynamic> json) =>
      _$Model136FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model136ToJson(this);
}
