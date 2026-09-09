import 'package:json_annotation/json_annotation.dart';

part 'model_248.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model248 {
  const Model248({required this.id, required this.value});

  final int id;
  final String value;

  factory Model248.fromJson(Map<String, dynamic> json) =>
      _$Model248FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model248ToJson(this);
}
