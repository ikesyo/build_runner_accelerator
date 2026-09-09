import 'package:json_annotation/json_annotation.dart';

part 'model_182.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model182 {
  const Model182({required this.id, required this.value});

  final int id;
  final String value;

  factory Model182.fromJson(Map<String, dynamic> json) =>
      _$Model182FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model182ToJson(this);
}
