import 'package:json_annotation/json_annotation.dart';

part 'model_249.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model249 {
  const Model249({required this.id, required this.value});

  final int id;
  final String value;

  factory Model249.fromJson(Map<String, dynamic> json) =>
      _$Model249FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model249ToJson(this);
}
