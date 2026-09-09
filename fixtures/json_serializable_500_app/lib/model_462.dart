import 'package:json_annotation/json_annotation.dart';

part 'model_462.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model462 {
  const Model462({required this.id, required this.value});

  final int id;
  final String value;

  factory Model462.fromJson(Map<String, dynamic> json) =>
      _$Model462FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model462ToJson(this);
}
