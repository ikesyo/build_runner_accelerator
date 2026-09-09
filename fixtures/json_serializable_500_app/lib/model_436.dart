import 'package:json_annotation/json_annotation.dart';

part 'model_436.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model436 {
  const Model436({required this.id, required this.value});

  final int id;
  final String value;

  factory Model436.fromJson(Map<String, dynamic> json) =>
      _$Model436FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model436ToJson(this);
}
