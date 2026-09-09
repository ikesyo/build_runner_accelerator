import 'package:json_annotation/json_annotation.dart';

part 'model_389.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model389 {
  const Model389({required this.id, required this.value});

  final int id;
  final String value;

  factory Model389.fromJson(Map<String, dynamic> json) =>
      _$Model389FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model389ToJson(this);
}
