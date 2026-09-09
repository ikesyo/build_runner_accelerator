import 'package:json_annotation/json_annotation.dart';

part 'model_200.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model200 {
  const Model200({required this.id, required this.value});

  final int id;
  final String value;

  factory Model200.fromJson(Map<String, dynamic> json) =>
      _$Model200FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model200ToJson(this);
}
