import 'package:json_annotation/json_annotation.dart';

part 'model_131.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model131 {
  const Model131({required this.id, required this.value});

  final int id;
  final String value;

  factory Model131.fromJson(Map<String, dynamic> json) =>
      _$Model131FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model131ToJson(this);
}
